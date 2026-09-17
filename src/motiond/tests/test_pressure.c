/* Run: gcc -Wall -Wextra -Werror -O2 test_pressure.c -lrt -o /tmp/test-pressure
 *      /tmp/test-pressure
 * Fake procfs and time; never opens the real VE node or sends motion IPC.
 */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <string.h>

static const char *buddy;
static const char *ve =
    "Channel[0]\nScene:7, Move:1, MovingLevel:2, BinImgRatio:3.25%, MovingTh:20\nEnd Channel[0]\n"
    "Channel[1]\nScene:0, Move:0, MovingLevel:0, BinImgRatio:0.0%, MovingTh:1\nEnd Channel[1]\n";
static int opens, buddy_reads, open_error, read_error;
static long long now_ms;
static FILE *fake_fopen(const char *path, const char *mode) {
    assert(strcmp(path, "/proc/buddyinfo") == 0);
    assert(strcmp(mode, "r") == 0);
    ++buddy_reads;
    if (!buddy) { errno = ENOENT; return NULL; }
    FILE *fp = tmpfile();
    assert(fp);
    assert(fputs(buddy, fp) >= 0);
    rewind(fp);
    return fp;
}
static int fake_open(const char *path, int flags, ...) {
    (void)flags;
    assert(strcmp(path, "/sys/kernel/debug/mpp/ve") == 0);
    ++opens;
    if (open_error) { errno = open_error; return -1; }
    return 123;
}
static ssize_t fake_read(int fd, void *buf, size_t size) {
    assert(fd == 123);
    if (read_error) { errno = read_error; return -1; }
    size_t n = strlen(ve);
    assert(n <= size);
    memcpy(buf, ve, n);
    return (ssize_t)n;
}
static int fake_close(int fd) { assert(fd == 123); return 0; }
static int fake_clock_gettime(clockid_t id, struct timespec *ts) {
    assert(id == CLOCK_MONOTONIC);
    ts->tv_sec = now_ms / 1000;
    ts->tv_nsec = (now_ms % 1000) * 1000000;
    return 0;
}
#define fopen fake_fopen
#define open fake_open
#define read fake_read
#define close fake_close
#define clock_gettime fake_clock_gettime
#define main motiond_main
#include "../motiond/motiond.c"
#undef main

int main(void) {
    const struct { const char *text; int ok; } cases[] = {
        {NULL, 0}, {"", 0}, {"garbage\n", 0},
        {"Node 0, zone Normal 99 99 99 0 0 0 0 0 0 0 0\n", 0},
        {"Node 0, zone Normal 0 0 0 1\n", 0},
        {"Node 0, zone Normal 0 0 0 3\n", 0},
        {"Node 0, zone Normal 0 0 0 4\n", 1},
        {"Node 0, zone Normal 0 0 0 0 2\n", 1},
        {"Node 0, zone Normal 0 0 0 0 0 1\n", 1},
        {"Node 0, zone Normal 0 0 0 2 1\n", 1},
        {"Node 0, zone Normal 0 0 0 0 0 0 0 0 0 0 0 1\n", 1},
        {"Node 0, zone DMA 0 0 0 99\nNode 0, zone Normal 0 0 0 0\n", 0},
        {"Node 0, zone HighMem 0 0 0 99\n", 0},
        {"Node 0, zone Normal 0 0 0 2\nNode 1, zone Normal 0 0 0 2\n", 0},
        {"Node 0, zone Normal 0 0 0 0\nNode 1, zone Normal 0 0 0 4\n", 1},
        {"Node 0, zone Normal 0 0 0 4", 0},
        {"Node 0, zone Normal 0 0\n", 0},
        {"Node 0, zone Normal 0 0 0 -4\n", 0},
        {"Node 0, zone Normal 0 0 0 4 junk\n", 0},
        {"Node 0, zone Normal 0 0 0 999999999999999999999999\n", 0},
        {"Node 0, zone Normal 0 0 0 4294967295\n", 1},
    };
    struct motion_stats s = {.scene = 1234};
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        buddy = cases[i].text;
        assert(ve_order3_reserve_ok() == cases[i].ok);
        ve_retry_after_ms = 0;
        opens = 0;
        s.scene = 1234;
        assert((read_stats(&s) == 0) == cases[i].ok);
        assert(opens == cases[i].ok);
        if (!cases[i].ok) { assert(errno == EAGAIN); assert(s.scene == 1234); }
        else { assert(s.scene == 7); assert(s.move == 1); assert(s.moving_level == 2); assert(s.bin_ratio == 3.25); assert(s.moving_th == 20); }
    }
    char long_line[1024];
    memset(long_line, ' ', sizeof(long_line));
    memcpy(long_line, "Node 0, zone Normal 0 0 0 4", 27);
    long_line[sizeof(long_line)-2] = '\n';
    long_line[sizeof(long_line)-1] = 0;
    buddy = long_line;
    assert(!ve_order3_reserve_ok());

    buddy = "Node 0, zone Normal 0 0 0 0\n";
    now_ms = 1000; ve_retry_after_ms = 0; opens = 0;
    assert(read_stats(&s) == -5);
    int checked = buddy_reads;
    buddy = "Node 0, zone Normal 0 0 0 4\n";
    for (now_ms = 1100; now_ms < 1500; now_ms += 100) assert(read_stats(&s) == -5);
    assert(opens == 0 && buddy_reads == checked);
    assert(read_stats(&s) == 0 && opens == 1);
    now_ms += 100;
    assert(read_stats(&s) == 0 && opens == 2); /* Normal 100 ms sampling. */

    const int failures[] = {ENOMEM, ENFILE, EMFILE, EAGAIN, EIO};
    for (size_t i = 0; i < sizeof(failures)/sizeof(failures[0]); ++i) {
        for (int at_read = 0; at_read < 2; ++at_read) {
            now_ms += 1000;
            open_error = at_read ? 0 : failures[i];
            read_error = at_read ? failures[i] : 0;
            assert(read_stats(&s) == -1 && errno == failures[i]);
            int attempted = opens;
            long long deadline = now_ms + 1000;
            open_error = read_error = 0;
            for (now_ms += 100; now_ms < deadline; now_ms += 100)
                assert(read_stats(&s) == -5);
            assert(opens == attempted);
            assert(read_stats(&s) == 0 && opens == attempted + 1);
        }
    }
    ve = "";
    now_ms += 100;
    assert(read_stats(&s) == -1 && errno == EIO);
    ve = "incomplete vendor output";
    now_ms += 1000;
    assert(read_stats(&s) == -2);
    now_ms += 100;
    assert(read_stats(&s) == -5);
    puts("PASS: Normal-zone parsing, fail-closed guard, no unsafe opens, unchanged failed samples, 500/1000 ms backoff, 100 ms success cadence");
    return 0;
}
