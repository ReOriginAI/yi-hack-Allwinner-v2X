// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#include "motion_metadata_events.h"
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define HISTORY_MAGIC 0x59494d31U
struct shared_history {
    uint32_t magic, version;
    _Atomic uint32_t sequence;
    uint32_t reserved;
    struct motion_history history;
};
static struct shared_history *writer;
static const struct shared_history *reader;

static const char *history_path(void) {
    const char *value = getenv("YI_MOTION_EVENTS");
    return value && value[0] == '/' ? value : "/tmp/yi-motion-events";
}

int64_t motion_wall_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void motion_history_add(struct motion_history *history, int state, int64_t unix_ms) {
    if (state == history->last_state) return;
    if (history->count == EVENT_CAPACITY) {
        history->baseline_ms = history->events[history->first].unix_ms;
        history->baseline_state = history->events[history->first].state;
        history->baseline_is_sample = 0;
        history->first = (history->first + 1) % EVENT_CAPACITY;
        --history->count;
    }
    uint32_t index = (history->first + history->count++) % EVENT_CAPACITY;
    history->events[index].unix_ms = unix_ms;
    history->events[index].state = history->last_state = state;
}

int motion_history_start(void) {
    int fd = open(history_path(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, sizeof(struct shared_history))) { close(fd); return -1; }
    writer = mmap(NULL, sizeof(*writer), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (writer == MAP_FAILED) { writer = NULL; return -1; }
    // ipc2file is the sole writer. Reset in place so existing readers stay valid.
    uint32_t previous = atomic_load_explicit(&writer->sequence, memory_order_relaxed);
    previous += previous & 1;
    atomic_store_explicit(&writer->sequence, previous + 1, memory_order_seq_cst);
    writer->magic = HISTORY_MAGIC;
    writer->version = 1;
    memset(&writer->history, 0, sizeof(writer->history));
    writer->history.baseline_ms = motion_wall_ms();
    writer->history.baseline_state = -1;
    writer->history.baseline_is_sample = 1;
    char model[16] = {0};
    const char *value = getenv("YI_RECORD_METADATA_MODEL");
    if (value) strncpy(model, value, sizeof(model) - 1);
    else {
        fd = open("/tmp/sd/yi-hack/model_suffix", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            if (read(fd, model, sizeof(model) - 1) < 0) model[0] = 0;
            close(fd);
        }
        model[strcspn(model, "\r\n")] = 0;
    }
    if (!strcmp(model, "y623")) {
        char state;
        fd = open("/tmp/motion.state", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            if (read(fd, &state, 1) == 1 && (state == '0' || state == '1'))
                writer->history.baseline_state = state - '0';
            close(fd);
        }
    } else if (!strcmp(model, "y28ga")) {
        writer->history.baseline_state = access("/tmp/onvif_notify_server/motion_alarm", F_OK) == 0;
    }
    writer->history.last_state = writer->history.baseline_state;
    atomic_store_explicit(&writer->sequence, previous + 2, memory_order_release);
    return 0;
}

void motion_history_observe(int state, int64_t unix_ms) {
    if (!writer || state == writer->history.last_state) return;
    atomic_fetch_add_explicit(&writer->sequence, 1, memory_order_acq_rel);
    motion_history_add(&writer->history, state, unix_ms);
    atomic_fetch_add_explicit(&writer->sequence, 1, memory_order_release);
}

int motion_history_read(struct motion_history *history) {
    if (!reader) {
        int fd = open(history_path(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) return -1;
        struct stat st;
        if (fstat(fd, &st) || st.st_size != sizeof(struct shared_history)) { close(fd); return -1; }
        reader = mmap(NULL, sizeof(*reader), PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (reader == MAP_FAILED) { reader = NULL; return -1; }
    }
    // Bounded snapshot, never block or spin indefinitely during clip closure.
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint32_t before = atomic_load_explicit(&reader->sequence, memory_order_acquire);
        if (before & 1) continue;
        memcpy(history, &reader->history, sizeof(*history));
        atomic_thread_fence(memory_order_acquire);
        if (before == atomic_load_explicit(&reader->sequence, memory_order_relaxed) &&
            reader->magic == HISTORY_MAGIC && reader->version == 1 &&
            history->first < EVENT_CAPACITY && history->count <= EVENT_CAPACITY)
            return 0;
    }
    return -1;
}
