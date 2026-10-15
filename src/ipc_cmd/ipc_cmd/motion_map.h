#ifndef YI_MOTION_MAP_H
#define YI_MOTION_MAP_H
#include <stdint.h>
#ifndef MOTION_MAP_PATH
#define MOTION_MAP_PATH "/tmp/yi-motion-map"
#endif
#define MOTION_MAP_MAGIC 0x594d4150U
#define MOTION_MAP_VERSION 2U
#define MOTION_MAP_LEGACY_VERSION 1U
#define MOTION_MAP_COLS 40U
#define MOTION_MAP_ROWS 23U
#define MOTION_MAP_BLOCKS (MOTION_MAP_COLS * MOTION_MAP_ROWS)
#define MOTION_MASK_COLS 20U
#define MOTION_MASK_ROWS 12U
#define MOTION_MASK_CELLS (MOTION_MASK_COLS * MOTION_MASK_ROWS)
/* One encoder-owner writer, one detector reader. generation is a seqlock;
 * enabled is the reader's request. The writer never waits for a reader. */
struct motion_map_frame {
    uint32_t pid, frame, p_frame, reserved;
    int64_t monotonic_ms;
    unsigned char vectors[MOTION_MAP_BLOCKS * 8];
    unsigned char difference[MOTION_MAP_BLOCKS];
};
struct motion_map_shared {
    uint32_t magic, version, enabled, generation, reader_ms, reserved;
    struct motion_map_frame sample;
};
#endif
