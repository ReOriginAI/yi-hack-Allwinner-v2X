#ifndef MOTION_TUNING_H
#define MOTION_TUNING_H

#include <math.h>
#include <stddef.h>

struct motion_stats {
    int scene, move, moving_level;
    double bin_ratio;
    int moving_th;
};

struct sens_cfg {
    double trigger, release;
    int confirm_samples, quiet_ms, require_zero, level_boost;
};

static const struct sens_cfg cfgs[10] = {
    {15.00, 1.50, 5, 2000, 1, 1},
    {10.00, 1.00, 5, 2000, 1, 1},
    { 7.00, 0.70, 4, 2000, 1, 1},
    { 5.00, 0.50, 4, 2000, 1, 1},
    { 3.00, 0.30, 3, 2000, 1, 1},
    { 2.00, 0.20, 3, 2000, 1, 1},
    { 1.20, 0.15, 3, 2000, 1, 1},
    { 0.80, 0.15, 2, 2000, 1, 1},
    { 0.50, 0.15, 2, 2000, 1, 1},
    { 0.25, 0.15, 2, 2000, 1, 1},
};

struct motion_detector {
    int active, positives;
    long long quiet_since;
};

static int motion_config_valid(const struct sens_cfg *c, int interval_ms) {
    return isfinite(c->trigger) && isfinite(c->release) &&
        c->trigger >= 0.01 && c->trigger <= 100 &&
        c->release >= 0 && c->release < c->trigger &&
        c->confirm_samples >= 1 && c->confirm_samples <= 50 &&
        c->quiet_ms >= 100 && c->quiet_ms <= 30000 &&
        (c->require_zero == 0 || c->require_zero == 1) &&
        interval_ms >= 100 && interval_ms <= 2000;
}

/* Returns START=1, STOP=-1, unchanged=0. Invalid/missing observations reset
 * confirmation and quiet timing, but never invent a state transition. */
static int motion_update(struct motion_detector *d, const struct sens_cfg *c,
                         const struct motion_stats *s, long long now) {
    if (!s || !isfinite(s->bin_ratio) || s->bin_ratio < 0 ||
        s->bin_ratio > 100 || s->moving_level < 0) {
        d->positives = 0;
        d->quiet_since = -1;
        return 0;
    }
    if (!d->active) {
        int strong = s->bin_ratio >= c->trigger ||
            (c->level_boost && s->moving_level >= 2 &&
             s->bin_ratio >= c->trigger * 0.5);
        d->positives = strong ? d->positives + 1 : 0;
        if (d->positives >= c->confirm_samples) {
            d->active = 1;
            d->quiet_since = -1;
            return 1;
        }
    } else {
        int quiet = s->bin_ratio <= c->release &&
            (!c->require_zero || s->moving_level == 0);
        if (!quiet) d->quiet_since = -1;
        else {
            if (d->quiet_since < 0) d->quiet_since = now;
            if (now - d->quiet_since >= c->quiet_ms) {
                d->active = d->positives = 0;
                d->quiet_since = -1;
                return -1;
            }
        }
    }
    return 0;
}
#endif
