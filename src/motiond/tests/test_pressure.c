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

static const char *buddy, *kernel_symbols, *kernel_iomem;
static unsigned char alloc_call[4], release_call[4];
static int mem_error, mem_read_error, mem_short, mem_reads, mem_opens, mem_closes;
static const char *ve =
    "Channel[0]\nScene:7, Move:1, MovingLevel:2, BinImgRatio:3.25%, MovingTh:20\nEnd Channel[0]\n"
    "Channel[1]\nScene:0, Move:0, MovingLevel:0, BinImgRatio:0.0%, MovingTh:1\nEnd Channel[1]\n";
static int opens, buddy_reads, open_error, read_error;
static long long now_ms;
static FILE *fake_fopen(const char *path, const char *mode) {
    assert(strcmp(mode, "r") == 0);
    const char *data;
    if (strcmp(path, "/proc/buddyinfo") == 0) { ++buddy_reads; data = buddy; }
    else if (strcmp(path, "/proc/kallsyms") == 0) data = kernel_symbols;
    else { assert(strcmp(path, "/proc/iomem") == 0); data = kernel_iomem; }
    if (!data) { errno = ENOENT; return NULL; }
    FILE *fp = tmpfile();
    assert(fp);
    assert(fputs(data, fp) >= 0);
    rewind(fp);
    return fp;
}
static int fake_open(const char *path, int flags, ...) {
    assert(flags == (O_RDONLY | O_CLOEXEC));
    if (strcmp(path, "/dev/mem") == 0) {
        ++mem_opens;
        if (mem_error) { errno = mem_error; return -1; }
        return 124;
    }
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
static ssize_t fake_pread(int fd, void *buf, size_t size, off_t offset) {
    assert(fd == 124 && size == 4);
    ++mem_reads;
    if (mem_read_error) { errno = mem_read_error; return -1; }
    assert(offset == (off_t)0x4018c42c || offset == (off_t)0x4018c414);
    memcpy(buf, offset == (off_t)0x4018c42c ? alloc_call : release_call, size);
    return (mem_short == 1 && offset == (off_t)0x4018c42c) ||
           (mem_short == 2 && offset == (off_t)0x4018c414) ? 3 : 4;
}
static int fake_close(int fd) {
    assert(fd == 123 || fd == 124);
    if (fd == 124) ++mem_closes;
    return 0;
}
static int fake_clock_gettime(clockid_t id, struct timespec *ts) {
    assert(id == CLOCK_MONOTONIC);
    ts->tv_sec = now_ms / 1000;
    ts->tv_nsec = (now_ms % 1000) * 1000000;
    return 0;
}
#define fopen fake_fopen
#define open fake_open
#define read fake_read
#define pread fake_pread
#define close fake_close
#define clock_gettime fake_clock_gettime
#define main motiond_main
#include "../motiond/motiond.c"
#undef main

static void test_allocator_verification(void) {
    const char *symbols =
        "c018c40e t ve_debugfs_release\n"
        "c018c41e t ve_debugfs_open\n"
        "c0072f1c T vfree\n"
        "c0073198 T vmalloc\n";
    const char *iomem =
        "030090a0-030090bf : watchdog\n"
        "40000000-43ffffff : System RAM\n"
        "  40008000-40357fff : Kernel code\n";
    kernel_symbols = symbols;
    kernel_iomem = iomem;
    memcpy(alloc_call, "\xe6\xf6\xb4\xfe", 4);
    memcpy(release_call, "\xe6\xf6\x82\xfd", 4);
    assert(ve_vmalloc_verified());
    assert(mem_reads == 2 && mem_opens == 1 && mem_closes == 1);

    /* Stock and either half-applied patch must retain the guard. */
    memcpy(alloc_call, "\xd9\xf6\x58\xfc", 4);
    assert(!ve_vmalloc_verified());
    memcpy(release_call, "\xed\xf6\x6c\xff", 4);
    assert(!ve_vmalloc_verified());
    memcpy(alloc_call, "\xe6\xf6\xb4\xfe", 4);
    assert(!ve_vmalloc_verified());
    memcpy(release_call, "\xe6\xf6\x82\xfd", 4);

    mem_error = EACCES;
    int closed = mem_closes;
    assert(!ve_vmalloc_verified() && mem_closes == closed);
    mem_error = 0;
    mem_short = 1;
    assert(!ve_vmalloc_verified() && mem_closes == closed + 1);
    mem_short = 2;
    assert(!ve_vmalloc_verified() && mem_closes == closed + 2);
    mem_short = 0;
    mem_read_error = EIO;
    assert(!ve_vmalloc_verified() && mem_closes == closed + 3);
    mem_read_error = 0;

    /* Never even open physical memory on unknown/incomplete metadata. */
    int attempted = mem_opens;
    kernel_symbols = NULL;
    assert(!ve_vmalloc_verified());
    kernel_symbols = "c018c41e t ve_debugfs_open\n";
    assert(!ve_vmalloc_verified());
    kernel_symbols =
        "00000000 t ve_debugfs_release\nc018c41e t ve_debugfs_open\n"
        "c0072f1c T vfree\nc0073198 T vmalloc\n";
    assert(!ve_vmalloc_verified());
    kernel_symbols =
        "c018c40e t ve_debugfs_release\nc018c41e t ve_debugfs_open\n"
        "c0072f1c T vfree\nc0073198 T vmalloc\nc0073198 T vmalloc\n";
    assert(!ve_vmalloc_verified());
    kernel_symbols = symbols;
    kernel_iomem = NULL;
    assert(!ve_vmalloc_verified());
    kernel_iomem = "40000000-43ffffff : System RAM\n";
    assert(!ve_vmalloc_verified());
    kernel_iomem = "50000000-53ffffff : System RAM\n  50008000-50357fff : Kernel code\n";
    assert(!ve_vmalloc_verified());
    assert(mem_opens == attempted);
    kernel_iomem = iomem;
    assert(ve_vmalloc_verified());
    assert(mem_closes == mem_opens - 1); /* One denied open, no fd to close. */
}

int main(void) {
    test_allocator_verification();
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

    /* Verified vmalloc must sample through fragmented/missing buddyinfo,
     * without opening buddyinfo or altering confirmation via fake skips. */
    ve_uses_vmalloc = 1;
    buddy = NULL;
    now_ms += 1000; ve_retry_after_ms = 0; opens = 0;
    checked = buddy_reads;
    for (int i = 0; i < 5; ++i, now_ms += 100)
        assert(read_stats(&s) == 0);
    assert(opens == 5 && buddy_reads == checked);
    buddy = "Node 0, zone Normal 0 0 0 0\n";
    assert(read_stats(&s) == 0 && buddy_reads == checked);
    buddy = "Node 0, zone Normal 0 0 0 4\n";

    const int failures[] = {ENOMEM, ENFILE, EMFILE, EAGAIN, EIO};
    for (ve_uses_vmalloc = 0; ve_uses_vmalloc <= 1; ++ve_uses_vmalloc) {
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
    }
    ve_uses_vmalloc = 1;
    ve = "";
    now_ms += 100;
    assert(read_stats(&s) == -1 && errno == EIO);
    ve = "incomplete vendor output";
    now_ms += 1000;
    assert(read_stats(&s) == -2);
    now_ms += 100;
    assert(read_stats(&s) == -5);
    puts("PASS: running-kernel vmalloc/vfree verification, fail-closed fallback, fragmented vmalloc sampling, legacy reserve guard, both-mode error backoff and 100 ms cadence");
    return 0;
}
