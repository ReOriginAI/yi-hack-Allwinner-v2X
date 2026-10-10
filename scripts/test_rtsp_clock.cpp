// SPDX-License-Identifier: GPL-3.0-only
#include "FrameClock.hh"
#include <cassert>
#include <cstdio>

static int64_t usec(struct timeval value) {
    return (int64_t)value.tv_sec * 1000000 + value.tv_usec;
}

int main() {
    struct timeval wall = {100, 200000};
    FrameClock clock(1000, wall);
    assert(usec(clock.map(1000)) == 100200000);
    // An older audio queue must share the video's origin, not re-anchor to now.
    assert(usec(clock.map(960)) == 100160000);
    assert(usec(clock.map(1064)) == 100264000);
    // A fresh video reader and persistent audio replica use one timeline.
    assert(usec(clock.map(5000)) == 104200000);
    assert(usec(clock.map(5064)) == 104264000);

    FrameClock wrapped(0xfffffff0U, wall);
    assert(usec(wrapped.map(0x20U)) == 100248000);
    // Track interleaving on either side of the wrap is reversible.
    assert(usec(wrapped.map(0xffffffe0U)) == 100184000);
    assert(usec(wrapped.map(0x60U)) == 100312000);

    // More than one complete uint32 millisecond clock period (~50 days).
    FrameClock longRun(0, wall);
    uint32_t frame = 0;
    for (int i = 1; i <= 100000; ++i) {
        frame += 64000;
        assert(usec(longRun.map(frame)) == 100200000 + (int64_t)i * 64000000);
    }
    std::puts("PASS: shared audio/video clock, reconnects, interleaving and timestamp wrap");
}
