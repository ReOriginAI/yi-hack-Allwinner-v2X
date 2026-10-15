// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include "motion_metadata_levels.h"
#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define LEVEL_MAGIC 0x59494c31U
struct shared_levels {
    uint32_t magic, version;
    _Atomic uint32_t sequence;
    uint32_t reserved;
    struct motion_levels history;
};
static struct shared_levels *level_writer;
static const struct shared_levels *level_reader;
static dev_t level_device;
static ino_t level_inode;
static atomic_flag level_reader_lock = ATOMIC_FLAG_INIT;
static int64_t last_wall, last_mono;
static int sampling_active, burst_count;
static int64_t next_sample_ms;

static const char *levels_path(void) {
    const char *value = getenv("YI_MOTION_LEVELS");
    return value && value[0] == '/' ? value : "/tmp/yi-motion-levels";
}

static void reset_levels(int64_t unix_ms) {
    memset(&level_writer->history, 0, sizeof(level_writer->history));
    level_writer->history.started_ms = unix_ms;
    level_writer->history.discarded_ms = -1;
    level_writer->history.observed_until_ms = unix_ms;
}

int motion_levels_start(void) {
    int fd = open(levels_path(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, sizeof(struct shared_levels))) { close(fd); return -1; }
    if (level_writer) munmap(level_writer, sizeof(*level_writer));
    level_writer = mmap(NULL, sizeof(*level_writer), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (level_writer == MAP_FAILED) { level_writer = NULL; return -1; }
    // motiond is the sole writer. Preserve mapped readers across restarts.
    uint32_t sequence = atomic_load_explicit(&level_writer->sequence, memory_order_relaxed);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    int64_t now = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    int retain = !(sequence & 1) && level_writer->magic == LEVEL_MAGIC &&
        level_writer->version == 2 && level_writer->history.first < LEVEL_CAPACITY &&
        level_writer->history.count <= LEVEL_CAPACITY &&
        level_writer->history.observed_until_ms <= now;
    sequence += sequence & 1;
    atomic_store_explicit(&level_writer->sequence, sequence + 1, memory_order_seq_cst);
    level_writer->magic = LEVEL_MAGIC;
    level_writer->version = 2;
    // Tuning restarts must retain samples for a recording still being written.
    // A corrupt/interrupted buffer or backward clock step needs fresh coverage.
    if (!retain) reset_levels(now);
    last_wall = last_mono = 0;
    sampling_active = burst_count = 0;
    next_sample_ms = 0;
    atomic_store_explicit(&level_writer->sequence, sequence + 2, memory_order_release);
    return 0;
}

int motion_levels_due(int active, int trigger, int64_t monotonic_ms) {
    if (!active) {
        sampling_active = burst_count = 0;
        return 0;
    }
    if (trigger || !sampling_active) {
        sampling_active = 1;
        burst_count = 0;
        next_sample_ms = monotonic_ms;
    }
    if (monotonic_ms < next_sample_ms) return 0;
    if (burst_count < LEVEL_BURST_SAMPLES) ++burst_count;
    next_sample_ms = monotonic_ms +
        (burst_count < LEVEL_BURST_SAMPLES ? LEVEL_BURST_MS : LEVEL_INTERVAL_MS);
    return 1;
}

void motion_levels_tick(int active, int valid, const struct motion_level_sample *sample,
                        int64_t monotonic_ms) {
    if (!level_writer || !sample) return;
    int64_t unix_ms = sample->unix_ms;
    atomic_fetch_add_explicit(&level_writer->sequence, 1, memory_order_acq_rel);
    // Do not bridge a manual/NTP clock step with apparently continuous history.
    if (last_mono && (unix_ms < last_wall ||
        llabs((unix_ms - last_wall) - (monotonic_ms - last_mono)) > 2000))
        reset_levels(unix_ms);
    last_wall = unix_ms;
    last_mono = monotonic_ms;
    struct motion_levels *h = &level_writer->history;
    h->observed_until_ms = unix_ms;
    if (active && valid && isfinite(sample->bin_ratio) && sample->bin_ratio >= 0 &&
        sample->bin_ratio <= 100 && sample->moving_level >= 0) {
        if (h->count == LEVEL_CAPACITY) {
            h->discarded_ms = h->samples[h->first].unix_ms;
            h->first = (h->first + 1) % LEVEL_CAPACITY;
            --h->count;
        }
        h->samples[(h->first + h->count++) % LEVEL_CAPACITY] = *sample;
    }
    atomic_fetch_add_explicit(&level_writer->sequence, 1, memory_order_release);
}

static int levels_snapshot(struct motion_levels *levels) {
    // Check once per completed clip; remap if motiond recreated the file.
    int fd = open(levels_path(), O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size != sizeof(struct shared_levels)) {
        if (fd >= 0) close(fd);
        if (level_reader) { munmap((void *)level_reader, sizeof(*level_reader)); level_reader = NULL; }
        return -1;
    }
    if (level_reader && (st.st_dev != level_device || st.st_ino != level_inode)) {
        munmap((void *)level_reader, sizeof(*level_reader));
        level_reader = NULL;
    }
    if (!level_reader) {
        level_reader = mmap(NULL, sizeof(*level_reader), PROT_READ, MAP_SHARED, fd, 0);
        if (level_reader == MAP_FAILED) { level_reader = NULL; close(fd); return -1; }
        level_device = st.st_dev;
        level_inode = st.st_ino;
    }
    close(fd);
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint32_t before = atomic_load_explicit(&level_reader->sequence, memory_order_acquire);
        if (before & 1) continue;
        memcpy(levels, &level_reader->history, sizeof(*levels));
        atomic_thread_fence(memory_order_acquire);
        if (before == atomic_load_explicit(&level_reader->sequence, memory_order_relaxed) &&
            level_reader->magic == LEVEL_MAGIC && level_reader->version == 2 &&
            levels->first < LEVEL_CAPACITY && levels->count <= LEVEL_CAPACITY)
            return 0;
    }
    return -1;
}

int motion_levels_read(struct motion_levels *levels) {
    if (atomic_flag_test_and_set_explicit(&level_reader_lock, memory_order_acquire)) return -1;
    int result = levels_snapshot(levels);
    atomic_flag_clear_explicit(&level_reader_lock, memory_order_release);
    return result;
}
