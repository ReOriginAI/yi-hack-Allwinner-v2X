// SPDX-License-Identifier: GPL-3.0-only
#include "record_metadata.c"
#include "motion_metadata_events.c"
#include <assert.h>

int main(void) {
    char path[] = "/tmp/yi-motion-unit-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && close(fd) == 0);
    assert(setenv("YI_MOTION_EVENTS", path, 1) == 0);
    assert(motion_history_start() == 0);
    struct motion_history *history = &writer->history;
    history->baseline_ms = 0; history->baseline_state = history->last_state = 0;
    model = "y623";
    motion_history_observe(1, 9000); motion_history_observe(1, 9500); // Deduplicate repeated START.
    motion_history_observe(0, 15000); motion_history_observe(1, 21000);
    struct movie movie = {.start_ms=10000, .duration_ms=10000};
    char json[JSON_CAPACITY];
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"initial_state\":1"));
    assert(strstr(json, "\"events\":[[5000,15000,0,\"transition\"]]"));
    assert(strstr(json, "\"history_truncated\":false"));
    movie.start_ms = 20000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"initial_state\":0"));
    assert(strstr(json, "\"events\":[[1000,21000,1,\"transition\"]]"));

    // A startup state sample is not a fabricated motion START timestamp.
    history->first = history->count = 0;
    history->baseline_ms = 12000; history->baseline_state = history->last_state = 1;
    history->baseline_is_sample = 1;
    movie.start_ms = 10000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"initial_state\":-1"));
    assert(strstr(json, "\"events\":[[2000,12000,1,\"sample\"]]"));

    // A writer interrupted during update must not expose a partial snapshot.
    atomic_fetch_add(&writer->sequence, 1);
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"history_available\":false"));
    assert(strstr(json, "\"initial_state\":-1"));
    assert(strstr(json, "\"events\":[]"));
    atomic_fetch_add(&writer->sequence, 1);

    history->first = history->count = 0; history->baseline_ms = 0; history->baseline_state = history->last_state = 0;
    for (int i = 1; i <= EVENT_CAPACITY + 20; ++i)
        motion_history_observe(i % 2, i * 1000);
    assert(history->count == EVENT_CAPACITY);
    movie.start_ms = 0; movie.duration_ms = 600000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"history_truncated\":true"));
    assert(strstr(json, "\"initial_state\":-1"));

    assert(recording_path("/tmp/sd/record/tmp.mp4.tmp", O_WRONLY|O_CREAT|O_TRUNC));
    assert(!recording_path("/tmp/sd/record/tmp.mp4.tmp", O_RDONLY));
    assert(!recording_path("/tmp/sd/record/tmp.mp4.tmp", O_RDWR));
    assert(!recording_path("/tmp/sd/record-other/test.mp4", O_WRONLY|O_CREAT|O_TRUNC));
    assert(!recording_path("/tmp/sd/record/test.txt", O_WRONLY|O_CREAT|O_TRUNC));
    assert(unlink(path) == 0);
    puts("PASS: shared event history, transitions, overlapping clips, bounded history and recording scope");

    char calendar[] = "/tmp/yi-calendar-unit-XXXXXX", info[256], recording[256];
    assert(mkdtemp(calendar));
    snprintf(info, sizeof(info), "%s/mmap.info", calendar);
    snprintf(recording, sizeof(recording), "%s/tmp.mp4.tmp", calendar);
    osd_info_path = info; record_root = calendar; model = "y28ga";
    int info_fd = open(info, O_RDWR|O_CREAT|O_TRUNC, 0600);
    assert(info_fd >= 0 && ftruncate(info_fd, 0x600) == 0);
    int32_t offset = -14400;
    assert(pwrite(info_fd, &offset, sizeof(offset), 0x4e0) == sizeof(offset));
    int recording_fd = open(recording, O_WRONLY|O_CREAT|O_TRUNC, 0600);
    assert(recording_fd >= 0);
    time_t utc = 1791684000, shifted = utc + offset;
    assert(recording_calendar_time(shifted, 0x12678) == utc);
    assert(recording_calendar_time(shifted, 0x117f8) == shifted);
    model = "y623";
    assert(recording_calendar_time(shifted, 0x12678) == shifted);
    model = "y28ga";
    offset = -18000; // An in-progress clip retains its opening DST offset.
    assert(pwrite(info_fd, &offset, sizeof(offset), 0x4e0) == sizeof(offset));
    assert(recording_calendar_time(shifted, 0x12678) == utc);
    assert(close(recording_fd) == 0 && close(info_fd) == 0);
    assert(setenv("TZ", "EST5EDT,M3.2.0,M11.1.0", 1) == 0);
    tzset();
    struct tm local;
    assert(localtime_r(&utc, &local) && local.tm_hour == 22 && local.tm_mday == 10);
    assert(unlink(recording) == 0 && unlink(info) == 0 && rmdir(calendar) == 0);
    puts("PASS: y28ga filename offset applied once, including clips spanning DST; other calendar calls retained");
}
