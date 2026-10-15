// SPDX-License-Identifier: GPL-3.0-only
#include "record_metadata.c"
#include "motion_metadata_events.c"
#include "motion_metadata_levels.c"
#include <assert.h>

static void level_tick(int active, int valid, double ratio, int level, int64_t wall, int64_t mono) {
    struct motion_level_sample raw = {.unix_ms=wall, .scene=2, .move=4,
        .moving_level=level, .bin_ratio=ratio, .moving_th=20};
    motion_levels_tick(active, valid, &raw, mono);
}

static void test_levels(void) {
    model = "y623";
    char path[] = "/tmp/yi-levels-unit-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && close(fd) == 0 && unlink(path) == 0);
    assert(setenv("YI_MOTION_LEVELS", path, 1) == 0);
    struct movie movie = {.start_ms=1000, .duration_ms=10000};
    char json[JSON_CAPACITY];
    assert(build_json(&movie, json) == -1); // Missing data produces no misleading empty tag.
    assert(motion_levels_start() == 0);
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"schema\":" MOTION_RAW_SCHEMA));
    assert(strstr(json, "\"data\":[]"));
    level_tick(0, 1, 1.0, 1, 2000, 1000);
    level_tick(1, 0, 7.5, 3, 3000, 2000);
    level_tick(1, 1, 3.255, 2, 4000, 3000);
    level_tick(1, 1, 8.5, 3, 5000, 4000);
    level_tick(1, 1, NAN, 1, 6000, 5000);
    level_tick(1, 1, 101, 1, 7000, 6000);
    level_tick(1, 1, 5, -1, 8000, 7000);
    assert(level_writer->history.count == 2);
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"data\":[[4000,2,4,2,3.255,20],[5000,2,4,3,8.5,20]]"));
    assert(!strstr(json, "events") && !strstr(json, "levels") && !strstr(json, "offset_ms"));
    movie.start_ms = 4500; movie.duration_ms = 2000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"data\":[[5000,2,4,3,8.5,20]]"));
    assert(motion_levels_start() == 0);
    assert(level_writer->history.count == 2); // Tuning restarts retain still-open clips.
    atomic_fetch_add(&level_writer->sequence, 1);
    assert(build_json(&movie, json) == -1);
    atomic_fetch_add(&level_writer->sequence, 1);

    // An immediate trigger and four 200 ms samples, then one-second cadence.
    assert(!motion_levels_due(0, 0, 900));
    assert(motion_levels_due(1, 1, 1000));
    for (int i = 1; i < LEVEL_BURST_SAMPLES; ++i) {
        assert(!motion_levels_due(1, 0, 1000 + i * 200 - 1));
        assert(motion_levels_due(1, 0, 1000 + i * 200));
    }
    assert(!motion_levels_due(1, 0, 2799));
    assert(motion_levels_due(1, 0, 2800));
    assert(!motion_levels_due(0, 0, 2900)); // STOP is not an active sample.
    assert(motion_levels_due(1, 1, 3000)); // A second motion gets its own trigger burst.
    assert(!motion_levels_due(1, 0, 3199));
    assert(motion_levels_due(1, 0, 3200));

    uint32_t transitions = writer->history.count;
    for (int i = 1; i <= LEVEL_CAPACITY + 20; ++i)
        level_tick(1, 1, 5, 2, 8000 + i * 1000, 7000 + i * 1000);
    assert(level_writer->history.count == LEVEL_CAPACITY);
    assert(writer->history.count == transitions);
    assert(level_writer->history.discarded_ms > 0);
    int64_t mono = 7000 + (LEVEL_CAPACITY + 20) * 1000;
    level_tick(1, 1, 5, 2, 1000000, mono + 1000); // Clock step starts new coverage.
    assert(level_writer->history.count == 1 && level_writer->history.started_ms == 1000000);
    level_tick(1, 1, 5, 2, 999999, mono + 2000);
    assert(level_writer->history.count == 1 && level_writer->history.started_ms == 999999);

    // A full raw ring fits the existing JSON allocation with normal vendor ranges.
    reset_levels(1700000000000LL);
    last_wall = last_mono = 0;
    for (int i = 0; i < LEVEL_CAPACITY; ++i)
        level_tick(1, 1, 99.99, 3, 1700000000000LL + i * 200, 1000 + i * 200);
    movie.start_ms = 1700000000000LL; movie.duration_ms = LEVEL_CAPACITY * 200;
    int json_size = build_json(&movie, json);
    assert(json_size > 0 && json_size < JSON_CAPACITY);
    assert(strstr(json, "\"schema\":" MOTION_RAW_SCHEMA));

    assert(unlink(path) == 0 && motion_levels_start() == 0);
    level_tick(1, 1, 2.0, 1, 5000, 1000);
    movie.start_ms = 1000; movie.duration_ms = 10000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"data\":[[5000,2,4,1,2,20]]"));
    assert(unlink(path) == 0);
    assert(build_json(&movie, json) == -1);
    puts("PASS: compact raw rows, active-only capture, trigger burst, clip windows, clock steps and file recovery");
}

int main(void) {
    char path[] = "/tmp/yi-motion-unit-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && close(fd) == 0);
    assert(setenv("YI_MOTION_EVENTS", path, 1) == 0);
    assert(motion_history_start() == 0);
    struct motion_history *history = &writer->history;
    history->baseline_ms = 0; history->baseline_state = history->last_state = 0;
    model = "y28ga";
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

    // A cached reader must report missing history, then recover when the
    // collector creates a new file without restarting the recorder.
    assert(unlink(path) == 0);
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"history_available\":false"));
    assert(strstr(json, "\"events\":[]"));
    assert(munmap(writer, sizeof(*writer)) == 0);
    writer = NULL;
    assert(motion_history_start() == 0);
    history = &writer->history;
    history->baseline_ms = -1000; history->baseline_state = history->last_state = 0;
    history->baseline_is_sample = 0;
    motion_history_observe(1, 5000);
    movie.start_ms = 0; movie.duration_ms = 10000;
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"history_available\":true"));
    assert(strstr(json, "\"events\":[[5000,5000,1,\"transition\"]]"));

    // Replacement can happen between reads, with no observed missing-file
    // interval. Reopening the path must find the new inode and its STOP event.
    assert(unlink(path) == 0);
    assert(munmap(writer, sizeof(*writer)) == 0);
    writer = NULL;
    assert(motion_history_start() == 0);
    history = &writer->history;
    history->baseline_ms = -1000; history->baseline_state = history->last_state = 1;
    history->baseline_is_sample = 0;
    motion_history_observe(0, 6000);
    assert(build_json(&movie, json) > 0);
    assert(strstr(json, "\"initial_state\":1"));
    assert(strstr(json, "\"events\":[[6000,6000,0,\"transition\"]]"));

    assert(recording_path("/tmp/sd/record/tmp.mp4.tmp", O_WRONLY|O_CREAT|O_TRUNC));
    assert(!recording_path("/tmp/sd/record/tmp.mp4.tmp", O_RDONLY));
    assert(!recording_path("/tmp/sd/record/tmp.mp4.tmp", O_RDWR));
    assert(!recording_path("/tmp/sd/record-other/test.mp4", O_WRONLY|O_CREAT|O_TRUNC));
    assert(!recording_path("/tmp/sd/record/test.txt", O_WRONLY|O_CREAT|O_TRUNC));
    test_levels();
    assert(unlink(path) == 0);
    puts("PASS: shared event history, transitions, overlapping clips, bounded history, missing/replaced-file recovery and recording scope");

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
