/* Uses private POSIX queues only; never opens the camera's real IPC queue. */
#define _POSIX_C_SOURCE 200809L
#include "../motiond/motion_delivery.h"
#include <assert.h>
#include <time.h>
#include <unistd.h>

static const unsigned char start[16] = {0x7c}, stop[16] = {0x7d}, filler[16] = {0};
static void receive(mqd_t mq, int first) {
    char message[16];
    assert(mq_receive(mq, message, sizeof(message), NULL) == 16);
    assert((unsigned char)message[0] == first);
}
static void empty(mqd_t mq) {
    char message[16];
    assert(mq_receive(mq, message, sizeof(message), NULL) == -1 && errno == EAGAIN);
}
static mqd_t create(const char *name, long size) {
    struct mq_attr attr = {.mq_maxmsg=1, .mq_msgsize=size};
    mqd_t mq = mq_open(name, O_CREAT | O_EXCL | O_RDWR | O_NONBLOCK, 0600, &attr);
    assert(mq != (mqd_t)-1);
    return mq;
}
int main(void) {
    char name[64];
    snprintf(name, sizeof(name), "/motiond-delivery-test-%ld", (long)getpid());
    mqd_t control = create(name, 16);
    struct motion_delivery d;
    motion_delivery_init(&d, 1, name);
    assert(motion_delivery_tick(&d, 0, start, stop) == 0);
    receive(control, 0x7d); /* Startup resets stale recorder motion. */
    assert(!motion_delivery_pending(&d));

    assert(!mq_send(control, (const char *)filler, 16, 0));
    motion_delivery_want(&d, 1);
    struct timespec before, after;
    assert(!clock_gettime(CLOCK_MONOTONIC, &before));
    assert(motion_delivery_tick(&d, 100, start, stop) == -1 && d.error == EAGAIN);
    assert(!clock_gettime(CLOCK_MONOTONIC, &after));
    assert((after.tv_sec-before.tv_sec)*1000000000LL + after.tv_nsec-before.tv_nsec < 500000000);
    assert(motion_delivery_pending(&d) && !d.sent);
    motion_delivery_want(&d, 0); /* Motion ends before the queue has room. */
    assert(motion_delivery_tick(&d, 200, start, stop) == -1 && d.error == EAGAIN);
    for (int i=0; i<100; ++i) { motion_delivery_want(&d, 1); motion_delivery_want(&d, 0); }
    receive(control, 0);
    assert(motion_delivery_tick(&d, 300, start, stop) == -1); /* START delivered, STOP pending. */
    receive(control, 0x7c);
    assert(d.sent && motion_delivery_pending(&d));
    assert(!motion_delivery_tick(&d, 400, start, stop));
    receive(control, 0x7d);
    assert(!motion_delivery_pending(&d));
    empty(control);

    motion_delivery_want(&d, 1);
    assert(!motion_delivery_tick(&d, 500, start, stop));
    receive(control, 0x7c);
    assert(!mq_send(control, (const char *)filler, 16, 0));
    motion_delivery_want(&d, 0);
    assert(motion_delivery_tick(&d, 600, start, stop) == -1);
    motion_delivery_want(&d, 1); /* Cancel an undelivered STOP when motion resumes. */
    assert(!motion_delivery_tick(&d, 700, start, stop));
    receive(control, 0);
    empty(control);

    assert(!mq_unlink(name));
    assert(motion_delivery_tick(&d, 1100, start, stop) == -1 && d.error == ENOENT);
    assert(d.mq == (mqd_t)-1 && motion_delivery_pending(&d));
    mqd_t recreated = create(name, 16);
    assert(motion_delivery_tick(&d, 2000, start, stop) == -1); /* Bounded reopen cadence. */
    empty(recreated);
    assert(motion_delivery_tick(&d, 2100, start, stop) == -1 && d.error == EAGAIN);
    receive(recreated, 0x7d);
    assert(!motion_delivery_tick(&d, 2200, start, stop));
    receive(recreated, 0x7c);
    empty(control); /* No writes into the unlinked old queue. */
    assert(!motion_delivery_pending(&d));

    assert(!mq_unlink(name));
    mqd_t replaced = create(name, 16);
    assert(motion_delivery_tick(&d, 3200, start, stop) == -1 && d.error == EAGAIN);
    receive(replaced, 0x7d);
    assert(!motion_delivery_tick(&d, 3300, start, stop));
    receive(replaced, 0x7c);
    empty(recreated);
    motion_delivery_want(&d, 0);
    assert(!motion_delivery_tick(&d, 3400, start, stop));
    receive(replaced, 0x7d);
    assert(!mq_close(d.mq)); /* Broken descriptor before the next identity check. */
    motion_delivery_want(&d, 1);
    assert(motion_delivery_tick(&d, 3500, start, stop) == -1 && d.error == EBADF);
    assert(d.mq == (mqd_t)-1);
    assert(motion_delivery_tick(&d, 4499, start, stop) == -1);
    assert(motion_delivery_tick(&d, 4500, start, stop) == -1 && d.error == EAGAIN);
    receive(replaced, 0x7d);
    assert(!motion_delivery_tick(&d, 4600, start, stop));
    receive(replaced, 0x7c);
    motion_delivery_want(&d, 0);
    assert(!motion_delivery_tick(&d, 4700, start, stop));
    receive(replaced, 0x7d);
    motion_delivery_close(&d);
    mq_close(control); mq_close(recreated); mq_close(replaced);
    assert(!mq_unlink(name));

    control = create(name, 8);
    motion_delivery_init(&d, 1, name);
    assert(motion_delivery_tick(&d, 0, start, stop) == -1 && d.error == EMSGSIZE);
    assert(d.mq == (mqd_t)-1);
    mq_close(control); assert(!mq_unlink(name));
    motion_delivery_init(&d, 0, name);
    motion_delivery_want(&d, 1);
    assert(!motion_delivery_tick(&d, 0, start, stop) && !motion_delivery_pending(&d));
    puts("PASS: nonblocking full queues, bounded pending bursts, reconnect, queue replacement and reset");
    return 0;
}
