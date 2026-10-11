// SPDX-License-Identifier: GPL-3.0-only
#ifndef YI_MOTION_METADATA_EVENTS_H
#define YI_MOTION_METADATA_EVENTS_H
#include <stdint.h>

#define EVENT_CAPACITY 512
struct motion_event { int64_t unix_ms; int state; };
struct motion_history {
    uint32_t first, count;
    int baseline_state, baseline_is_sample;
    int64_t baseline_ms;
    int last_state;
    struct motion_event events[EVENT_CAPACITY];
};

#define EVENT_API __attribute__((visibility("hidden")))
EVENT_API int motion_history_start(void);
EVENT_API void motion_history_observe(int state, int64_t unix_ms);
EVENT_API int motion_history_read(struct motion_history *history);
EVENT_API int64_t motion_wall_ms(void);
EVENT_API void motion_history_add(struct motion_history *history, int state, int64_t unix_ms);
#endif
