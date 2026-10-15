#ifndef MOTION_DELIVERY_H
#define MOTION_DELIVERY_H

#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

/* A stalled recorder must never stall the detector. Retain a pending START
 * and the latest state, rather than an unbounded backlog of stale transitions.
 * Several bursts during an outage can merge, but a short pending burst still
 * gets START followed by STOP. Startup/reconnection first clears stale motion.
 * Linux exposes mqueue descriptors as fds, allowing replacement detection. */
struct motion_delivery {
    mqd_t mq;
    const char *name;
    char path[128];
    int enabled, wanted, sent, start_pending, reset_pending, error;
    long long retry_after, check_after;
};

static void motion_delivery_init(struct motion_delivery *d, int enabled, const char *name) {
    memset(d, 0, sizeof(*d));
    d->mq = (mqd_t)-1;
    d->name = name;
    d->enabled = enabled;
    d->reset_pending = enabled;
    snprintf(d->path, sizeof(d->path), "/dev/mqueue%s", name);
}

static int motion_delivery_pending(const struct motion_delivery *d) {
    return d->enabled && (d->mq == (mqd_t)-1 || d->reset_pending ||
                         d->start_pending || d->sent != d->wanted);
}

static void motion_delivery_want(struct motion_delivery *d, int active) {
    if (!d->enabled) return;
    d->wanted = active;
    if (active && !d->sent) d->start_pending = 1;
}

static void motion_delivery_close(struct motion_delivery *d) {
    if (d->mq != (mqd_t)-1) mq_close(d->mq);
    d->mq = (mqd_t)-1;
}

static int motion_delivery_tick(struct motion_delivery *d, long long now,
                                const unsigned char *start, const unsigned char *stop) {
    if (!d->enabled) return 0;
    if (d->mq != (mqd_t)-1 && now >= d->check_after) {
        struct stat opened, current;
        if (fstat((int)d->mq, &opened) || stat(d->path, &current) ||
            opened.st_dev != current.st_dev || opened.st_ino != current.st_ino)
            motion_delivery_close(d);
        d->check_after = now + 1000;
    }
    if (d->mq == (mqd_t)-1) {
        if (now < d->retry_after) { errno = d->error; return -1; }
        d->mq = mq_open(d->name, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (d->mq == (mqd_t)-1) goto reconnect;
        struct mq_attr attr;
        if (mq_getattr(d->mq, &attr)) goto reconnect;
        if (attr.mq_msgsize < 16) { errno = EMSGSIZE; goto reconnect; }
        d->reset_pending = 1;
        if (d->wanted) d->start_pending = 1;
        d->check_after = now + 1000;
    }
    /* At most two nonblocking sends per detector tick. */
    for (int attempt = 0; attempt < 2 && motion_delivery_pending(d); ++attempt) {
        int active = d->reset_pending ? 0 : d->start_pending ? 1 : d->wanted;
        if (mq_send(d->mq, (const char *)(active ? start : stop), 16, 0)) {
            if (errno == EAGAIN || errno == EINTR) { d->error = errno; return -1; }
            goto reconnect;
        }
        d->sent = active;
        if (d->reset_pending) d->reset_pending = 0;
        else if (active) d->start_pending = 0;
    }
    d->error = 0;
    return 0;
reconnect:
    d->error = errno;
    motion_delivery_close(d);
    d->retry_after = now + 1000;
    errno = d->error;
    return -1;
}
#endif
