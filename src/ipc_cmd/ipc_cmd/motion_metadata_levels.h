// SPDX-License-Identifier: GPL-3.0-only
#ifndef YI_MOTION_METADATA_LEVELS_H
#define YI_MOTION_METADATA_LEVELS_H
#include <stdint.h>

#define LEVEL_CAPACITY 512
#define LEVEL_INTERVAL_MS 1000
#define LEVEL_BURST_SAMPLES 5
#define LEVEL_BURST_MS 200
#define MOTION_RAW_SCHEMA "[\"unix_ms\",\"Scene\",\"Move\",\"MovingLevel\",\"BinImgRatio\",\"MovingTh\"]"
struct motion_level_sample {
    int64_t unix_ms;
    double bin_ratio;
    int32_t scene, move, moving_level, moving_th;
};
struct motion_levels {
    uint32_t first, count;
    int64_t started_ms, discarded_ms, observed_until_ms;
    struct motion_level_sample samples[LEVEL_CAPACITY];
};

#define LEVEL_API __attribute__((visibility("hidden")))
LEVEL_API int motion_levels_start(void);
LEVEL_API int motion_levels_due(int active, int trigger, int64_t monotonic_ms);
LEVEL_API void motion_levels_tick(int active, int valid, const struct motion_level_sample *sample,
                                 int64_t monotonic_ms);
LEVEL_API int motion_levels_read(struct motion_levels *levels);
#endif
