#ifndef YI_RESET_HOTSPOT_H
#define YI_RESET_HOTSPOT_H
#include <stdint.h>
struct reset_press { uint64_t since; int tracking, fired; };
/* One event for a continuous five-second active-low press; release rearms it. */
static inline int reset_press_update(struct reset_press *press, int level, uint64_t now)
{
    if (level > 0) { press->tracking = press->fired = 0; return 0; }
    if (level < 0) { press->tracking = 0; return 0; }
    if (!press->tracking) { press->since = now; press->tracking = 1; }
    if (!press->fired && now >= press->since && now - press->since >= 5000) {
        press->fired = 1;
        return 1;
    }
    return 0;
}
#endif
