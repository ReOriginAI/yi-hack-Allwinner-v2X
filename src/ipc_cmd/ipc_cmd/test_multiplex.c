/* Host-side contract test; no live vendor queues are touched. */
#include "ipc_multiplex.h"
#include <assert.h>
#include <pthread.h>
#include <stdarg.h>

static int opens, sends, receive_error, sink_full, sink_failure;
static ssize_t receiver(mqd_t q, char *buf, size_t len, unsigned int *prio)
{
    (void)q; (void)prio;
    if (receive_error) { errno = EINTR; return -1; }
    assert(len >= 4);
    memcpy(buf, "test", 4);
    return 4;
}
static void *lookup(void *handle, const char *name)
{
    (void)handle;
    assert(strcmp(name, "mq_receive") == 0);
    return receiver;
}
static mqd_t open_sink(const char *name, int flags, ...)
{
    assert(flags & O_NONBLOCK);
    assert(strncmp(name, "/ipc_dispatch_", 14) == 0);
    opens++;
    if (sink_failure) { errno = EMFILE; return -1; }
    return opens + 10;
}
static int send_sink(mqd_t q, const char *buf, size_t len, unsigned int prio)
{
    assert(q >= 11 && len == 4 && prio == 1);
    assert(memcmp(buf, "test", 4) == 0);
    sends++;
    if (sink_full) { errno = EAGAIN; return -1; }
    return 0;
}
#define dlsym lookup
#define mq_open open_sink
#define mq_send send_sink
#include "ipc_multiplex.c"

int main(int argc, char **argv)
{
    char buf[512];
    int expected = getenv("IPC_MULTIPLEX_ALL") ? 9 : 1;
    sink_failure = argc > 1 && strcmp(argv[1], "no-sink") == 0;
    errno = EDOM;
    assert(mq_receive(0, buf, sizeof(buf), NULL) == 4);
    assert(errno == EDOM && opens == expected);
    assert(sends == (sink_failure ? 0 : expected));
    sink_full = 1;
    errno = EDOM;
    assert(mq_receive(0, buf, sizeof(buf), NULL) == 4);
    assert(errno == EDOM);
    int before = sends;
    receive_error = 1;
    assert(mq_receive(0, buf, sizeof(buf), NULL) == -1);
    assert(errno == EINTR && sends == before && opens == expected);
    puts("PASS: fan-out, full/missing sink, failed receive, errno");
    return 0;
}
