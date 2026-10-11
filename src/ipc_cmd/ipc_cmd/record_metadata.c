// SPDX-License-Identifier: GPL-3.0-only
// Recorder-local motion metadata. No worker, media copy, or completed-file job.
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "motion_metadata_events.h"
#define JSON_CAPACITY 32768
#define RECORD_FDS 4
#define MP4_EPOCH 2082844800ULL

struct movie {
    off_t offset, end;
    uint32_t size;
    int64_t start_ms, duration_ms;
};

static int tracked[RECORD_FDS] = {-1, -1, -1, -1};
static const char *record_root = "/tmp/sd/record";
static const char *model = "unknown";
static int debug;
static pthread_mutex_t fd_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t initialize_once = PTHREAD_ONCE_INIT;
static int (*real_open)(const char *, int, ...);
static int (*real_close)(int);
static struct tm *(*real_localtime_r)(const time_t *, struct tm *);
static const char *osd_info_path = "/tmp/mmap.info";
static _Thread_local int32_t clip_osd_offset;
static _Thread_local int clip_osd_offset_valid;
static int read_osd_offset(int32_t *offset);

static void initialize(void) {
    real_open = dlsym(RTLD_NEXT, "open");
    real_close = dlsym(RTLD_NEXT, "close");
    real_localtime_r = dlsym(RTLD_NEXT, "localtime_r");
    const char *value = getenv("YI_RECORD_ROOT");
    if (value && value[0] == '/' && strlen(value) < PATH_MAX - 32)
        record_root = value;
    value = getenv("YI_RECORD_METADATA_MODEL");
    if (value && (!strcmp(value, "y623") || !strcmp(value, "y28ga")))
        model = value;
    debug = getenv("YI_RECORD_METADATA_DEBUG") != NULL;
    value = getenv("YI_RECORD_OSD_INFO");
    if (value && value[0] == '/') osd_info_path = value;
}

static int recording_path(const char *path, int flags) {
    size_t root_len = strlen(record_root), len = strlen(path);
    return (flags & O_CREAT) && (flags & O_TRUNC) &&
        (flags & O_ACCMODE) != O_RDONLY &&
        !strncmp(path, record_root, root_len) && path[root_len] == '/' &&
        ((len >= 8 && !strcmp(path + len - 8, ".mp4.tmp")) ||
         (len >= 4 && !strcmp(path + len - 4, ".mp4")));
}

static int recording_open(const char *path, int flags, mode_t mode_bits) {
    int saved = errno;
    pthread_once(&initialize_once, initialize);
    if (!real_open) { errno = ENOSYS; return -1; }
    int recording = recording_path(path, flags);
    // Read only container headers on this same descriptor during muxer close.
    // Media bytes are never read back or copied by this library.
    if (recording) flags = (flags & ~O_ACCMODE) | O_RDWR;
    errno = saved;
    int fd = real_open(path, flags, mode_bits);
    saved = errno;
    if (recording && fd >= 0) {
        if (!strcmp(model, "y28ga"))
            clip_osd_offset_valid = read_osd_offset(&clip_osd_offset) == 0;
        pthread_mutex_lock(&fd_lock);
        for (size_t i = 0; i < RECORD_FDS; ++i) {
            if (tracked[i] == -1) { tracked[i] = fd; break; }
        }
        pthread_mutex_unlock(&fd_lock);
    }
    errno = saved;
    return fd;
}

// Explicit symbol names also cover libc headers redirecting open to open64.
int metadata_open(const char *path, int flags, ...) __asm__("open");
int metadata_open64(const char *path, int flags, ...) __asm__("open64");
static int needs_mode(int flags) {
    return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE;
}
int metadata_open(const char *path, int flags, ...) {
    mode_t mode_bits = 0;
    if (needs_mode(flags)) {
        va_list args;
        va_start(args, flags); mode_bits = va_arg(args, int); va_end(args);
    }
    return recording_open(path, flags, mode_bits);
}
int metadata_open64(const char *path, int flags, ...) {
    mode_t mode_bits = 0;
    if (needs_mode(flags)) {
        va_list args;
        va_start(args, flags); mode_bits = va_arg(args, int); va_end(args);
    }
    return recording_open(path, flags | O_LARGEFILE, mode_bits);
}

static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static uint64_t be64(const unsigned char *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static void store32(unsigned char *p, uint32_t value) {
    p[0] = value >> 24; p[1] = value >> 16; p[2] = value >> 8; p[3] = value;
}

static int read_at(int fd, void *buffer, size_t size, off_t offset) {
    unsigned char *p = buffer;
    while (size) {
        ssize_t n = pread(fd, p, size, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; offset += n; size -= n;
    }
    return 0;
}

static int read_osd_offset(int32_t *offset) {
    int fd = real_open(osd_info_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    int result = read_at(fd, offset, sizeof(*offset), 0x4e0);
    real_close(fd);
    return result || *offset < -86400 || *offset > 86400 ? -1 : 0;
}

static time_t recording_calendar_time(time_t value, uintptr_t caller) {
    // Both audited y28ga muxers add mmap.info's OSD offset before converting
    // the final MP4 filename at VA 0x12674. Undo this addition, then let libc
    // apply the full configured TZ rule exactly once. These are non-PIE ELFs.
    // Other calendar calls, y623, media timestamps and MP4 epochs are untouched.
    if (strcmp(model, "y28ga") || caller != 0x12678U || !clip_osd_offset_valid)
        return value;
    // Retain the opening offset if a clip closes across a DST change.
    int64_t corrected = (int64_t)value - clip_osd_offset;
    return (int64_t)(time_t)corrected == corrected ? (time_t)corrected : value;
}

struct tm *localtime_r(const time_t *value, struct tm *result) {
    int saved = errno;
    pthread_once(&initialize_once, initialize);
    if (!real_localtime_r) { errno = ENOSYS; return NULL; }
    time_t normalized = recording_calendar_time(*value, (uintptr_t)__builtin_return_address(0));
    errno = saved;
    return real_localtime_r(&normalized, result);
}

static int write_at(int fd, const void *buffer, size_t size, off_t offset) {
    const unsigned char *p = buffer;
    while (size) {
        ssize_t n = pwrite(fd, p, size, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n; offset += n; size -= n;
    }
    return 0;
}

static int find_movie(int fd, struct movie *movie) {
    struct stat st;
    unsigned char header[40];
    if (fstat(fd, &st) || st.st_size < 32) return -1;
    off_t offset = 0;
    // Skip mdat by its size, reading only the small container headers.
    for (unsigned int boxes = 0; boxes < 64 && offset <= st.st_size - 8; ++boxes) {
        if (read_at(fd, header, 8, offset)) return -1;
        uint64_t size = be32(header);
        size_t prefix = 8;
        if (size == 1) {
            if (read_at(fd, header + 8, 8, offset + 8)) return -1;
            size = be64(header + 8); prefix = 16;
        }
        if (size < prefix || size > (uint64_t)(st.st_size - offset)) return -1;
        if (!memcmp(header + 4, "moov", 4)) {
            // Audited muxers end with a normal, fully finalized moov atom.
            if (prefix != 8 || size > UINT32_MAX || offset + (off_t)size != st.st_size)
                return -1;
            movie->offset = offset; movie->size = size; movie->end = st.st_size;
            off_t child = offset + 8;
            for (unsigned int count = 0; count < 64 && child <= st.st_size - 8; ++count) {
                if (read_at(fd, header, 8, child)) return -1;
                uint32_t child_size = be32(header);
                if (child_size < 8 || child_size > (uint64_t)(st.st_size - child)) return -1;
                if (!memcmp(header + 4, "mvhd", 4)) {
                    if (child_size < 32 || read_at(fd, header, child_size < 40 ? child_size : 40, child))
                        return -1;
                    uint64_t creation, duration;
                    uint32_t scale;
                    if (header[8] == 0) {
                        creation = be32(header + 12); scale = be32(header + 20);
                        duration = be32(header + 24);
                    } else if (header[8] == 1 && child_size >= 40) {
                        creation = be64(header + 12); scale = be32(header + 28);
                        duration = be64(header + 32);
                    } else return -1;
                    if (!scale || creation < MP4_EPOCH ||
                        creation - MP4_EPOCH > INT64_MAX / 1000 ||
                        duration > UINT64_MAX / 1000) return -1;
                    movie->start_ms = (creation - MP4_EPOCH) * 1000;
                    movie->duration_ms = duration * 1000 / scale;
                    return movie->duration_ms > 0 && movie->duration_ms <= 86400000 ? 0 : -1;
                }
                child += child_size;
            }
            return -1;
        }
        offset += size;
    }
    return -1;
}

static int append_text(char *json, size_t *used, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int n = vsnprintf(json + *used, JSON_CAPACITY - *used, format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= JSON_CAPACITY - *used) return -1;
    *used += n;
    return 0;
}

static int build_json(const struct movie *movie, char *json) {
    size_t used = 0;
    struct motion_history history = {.baseline_state=-1, .last_state=-1, .baseline_ms=INT64_MAX};
    int available = motion_history_read(&history) == 0;
    if (!available) {
        memset(&history, 0, sizeof(history));
        history.baseline_state = history.last_state = -1;
        history.baseline_ms = INT64_MAX;
    }
    int initial = -1, truncated;
    int64_t end = movie->start_ms + movie->duration_ms;
    truncated = !available || history.baseline_ms > movie->start_ms;
    if (!truncated) initial = history.baseline_state;
    for (size_t i = 0; i < history.count; ++i) {
        const struct motion_event *event = &history.events[(history.first + i) % EVENT_CAPACITY];
        if (event->unix_ms <= movie->start_ms) initial = event->state;
    }
    int failed = append_text(json, &used,
        "{\"schema\":\"yi-motion-v1\",\"model\":\"%s\",\"source\":\"%s\","
        "\"video_start_unix_ms\":%" PRId64 ",\"duration_ms\":%" PRId64 ","
        "\"video_time_precision_ms\":1000,\"initial_state\":%d,"
        "\"history_available\":%s,\"history_truncated\":%s,\"event_columns\":[\"offset_ms\",\"unix_ms\",\"state\",\"kind\"],\"events\":[",
        model, !strcmp(model, "y623") ? "encoder-stats-ipc" : "firmware-iva-ipc",
        movie->start_ms, movie->duration_ms, initial, available ? "true" : "false", truncated ? "true" : "false");
    size_t included = 0;
    // Preserve a startup observation without inventing a motion START time.
    // This also establishes state after an unavailable preroll/history prefix.
    if (!failed && history.baseline_state >= 0 && history.baseline_ms >= movie->start_ms && history.baseline_ms <= end) {
        failed = append_text(json, &used, "[%" PRId64 ",%" PRId64 ",%d,\"%s\"]",
            history.baseline_ms - movie->start_ms, history.baseline_ms, history.baseline_state,
            history.baseline_is_sample ? "sample" : "transition");
        ++included;
    }
    for (size_t i = 0; !failed && i < history.count; ++i) {
        const struct motion_event *event = &history.events[(history.first + i) % EVENT_CAPACITY];
        if (event->unix_ms < movie->start_ms || event->unix_ms > end) continue;
        failed = append_text(json, &used, "%s[%" PRId64 ",%" PRId64 ",%d,\"transition\"]",
            included++ ? "," : "", event->unix_ms - movie->start_ms, event->unix_ms, event->state);
    }
    if (!failed) failed = append_text(json, &used, "]}");
    return failed ? -1 : (int)used;
}

static size_t begin_box(unsigned char *buffer, size_t *used, const char *type) {
    size_t start = *used;
    store32(buffer + start, 0);
    memcpy(buffer + start + 4, type, 4);
    *used += 8;
    return start;
}
static void end_box(unsigned char *buffer, size_t used, size_t start) {
    store32(buffer + start, used - start);
}

static int finalize_metadata(int fd) {
    struct movie movie;
    if (find_movie(fd, &movie)) return -1;
    // One transient bounded buffer, allocated only while closing a clip.
    unsigned char *buffer = calloc(1, JSON_CAPACITY + 256);
    if (!buffer) return -1;
    size_t used = 0, udta = begin_box(buffer, &used, "udta");
    size_t meta = begin_box(buffer, &used, "meta");
    used += 4;
    size_t hdlr = begin_box(buffer, &used, "hdlr");
    used += 8;
    memcpy(buffer + used, "mdir", 4); used += 4;
    used += 13;
    end_box(buffer, used, hdlr);
    size_t ilst = begin_box(buffer, &used, "ilst");
    size_t custom = begin_box(buffer, &used, "----");
    size_t mean = begin_box(buffer, &used, "mean");
    used += 4;
    memcpy(buffer + used, "com.yi-hack", 11); used += 11;
    end_box(buffer, used, mean);
    size_t name = begin_box(buffer, &used, "name");
    used += 4;
    memcpy(buffer + used, "yi_motion", 9); used += 9;
    end_box(buffer, used, name);
    size_t data = begin_box(buffer, &used, "data");
    store32(buffer + used, 1); used += 8; // UTF-8, locale 0
    int json_size = build_json(&movie, (char *)buffer + used);
    if (json_size < 0) { free(buffer); return -1; }
    used += json_size;
    end_box(buffer, used, data); end_box(buffer, used, custom);
    end_box(buffer, used, ilst); end_box(buffer, used, meta); end_box(buffer, used, udta);

    unsigned char old_size[4], new_size[4];
    store32(old_size, movie.size);
    store32(new_size, movie.size + used);
    int result = -1;
    if (movie.size <= UINT32_MAX - used && !write_at(fd, buffer, used, movie.end)) {
        if (!write_at(fd, new_size, 4, movie.offset)) result = 0;
        else write_at(fd, old_size, 4, movie.offset);
    }
    // A failed metadata write must leave the original playable container.
    if (result && ftruncate(fd, movie.end) && debug)
        fprintf(stderr, "record_metadata: rollback failed: %s\n", strerror(errno));
    if (debug) fprintf(stderr, "record_metadata: start=%" PRId64 " duration=%" PRId64
                       " bytes=%zu result=%d\n", movie.start_ms, movie.duration_ms, used, result);
    free(buffer);
    return result;
}

int close(int fd) {
    int saved = errno;
    pthread_once(&initialize_once, initialize);
    if (!real_close) { errno = ENOSYS; return -1; }
    int recording = 0;
    pthread_mutex_lock(&fd_lock);
    for (size_t i = 0; i < RECORD_FDS; ++i) {
        if (tracked[i] == fd) { tracked[i] = -1; recording = 1; break; }
    }
    pthread_mutex_unlock(&fd_lock);
    if (recording) finalize_metadata(fd);
    errno = saved;
    return real_close(fd);
}
