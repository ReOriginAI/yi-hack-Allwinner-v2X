// SPDX-License-Identifier: GPL-3.0-only
#ifndef FRAME_CLOCK_HH
#define FRAME_CLOCK_HH

#include <stdint.h>
#include <sys/time.h>

// One clock per capture thread, shared by all video and AAC queues. Mapping
// at capture time keeps reconnecting viewers and RTP/RTCP tracks in sync.
class FrameClock {
public:
    FrameClock(): fInitialized(false), fFrameTime(0), fWallUsec(0) {}
    FrameClock(uint32_t frameTime, struct timeval wall)
        : fInitialized(true), fFrameTime(frameTime),
          fWallUsec((int64_t)wall.tv_sec * 1000000 + wall.tv_usec) {}

    struct timeval map(uint32_t frameTime) {
        if (!fInitialized) {
            struct timeval wall;
            gettimeofday(&wall, nullptr);
            fWallUsec = (int64_t)wall.tv_sec * 1000000 + wall.tv_usec;
            fInitialized = true;
        } else {
            // Rebase on every captured frame: wraparound stays correct even
            // after months of uptime. Interleaved tracks may arrive earlier
            // than the previous track's frame and still use the same clock.
            fWallUsec += (int64_t)(int32_t)(frameTime - fFrameTime) * 1000;
        }
        fFrameTime = frameTime;
        struct timeval result;
        result.tv_sec = fWallUsec / 1000000;
        result.tv_usec = fWallUsec % 1000000;
        if (result.tv_usec < 0) {
            --result.tv_sec;
            result.tv_usec += 1000000;
        }
        return result;
    }

private:
    bool fInitialized;
    uint32_t fFrameTime;
    int64_t fWallUsec;
};
#endif
