#ifndef YI_NIGHTVISION_H
#define YI_NIGHTVISION_H

#include <stdint.h>

#ifndef NV_PATH
#define NV_PATH "/tmp/yi-nightvision"
#endif
#define NV_MAGIC UINT32_C(0x59494e56)
#define NV_VERSION 1
enum nv_mode { NV_AUTO, NV_ON, NV_OFF };

/* One small tmpfs mapping, shared with the existing firmware control loop. */
struct nv_control {
    uint32_t magic, version, generation, mode, threshold;
    uint32_t ready_pid, error, heartbeat, applied_generation;
    int32_t light_level, effective_level, state;
};

static inline int nv_level(int level, unsigned mode, unsigned threshold)
{
    if (mode == NV_ON) return 0;
    if (mode == NV_OFF) return 1000000;
    /* Failed measurements keep the firmware's original failure semantics. */
    if (level < 0 || threshold == 50) return level;
    int64_t scaled = (int64_t)level * 50 / threshold;
    return scaled > INT32_MAX ? INT32_MAX : (int)scaled;
}

#endif
