/* Optional interception of the audited physical reset poll only. No GPIO writes,
 * vendor text patch, IPC reset suppression, shell launch, or waiting in dispatch. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "reset_hotspot.h"
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <dlfcn.h>
#include <pthread.h>

#ifndef RESET_EXECUTABLE
#define RESET_EXECUTABLE "/proc/self/exe"
#endif
#ifndef RESET_ARMED
#define RESET_ARMED "/tmp/yi-reset-hotspot.armed"
#endif
#ifndef RESET_REQUEST
#define RESET_REQUEST "/tmp/yi-hotspot.request"
#endif
#ifdef __GLIBC__
typedef unsigned long ioctl_request_t;
#else
typedef int ioctl_request_t;
#endif
struct reset_profile { const char *model; uintptr_t caller; uint32_t words[3]; };
static const struct reset_profile profiles[] = {
    {"y623", 0x19b54, {0xe307100e, 0xe5960020, 0xebffdd24}},
    {"y28ga", 0x1864c, {0xe307100e, 0xe5960024, 0xebffe267}}
};
static const struct reset_profile *profile;
static struct reset_press press;
static int armed_reported;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int (*real_ioctl)(int, ioctl_request_t, ...);
static void resolve(void) { real_ioctl = dlsym(RTLD_NEXT, "ioctl"); }

__attribute__((constructor)) static void reset_initialize(void)
{
    const char *model = getenv("YI_RESET_HOTSPOT_MODEL");
    uint32_t words[3];
    if (!model || !*model) return;
    /* Child execs inherit LD_PRELOAD/env: check their ELF before using any
     * native addresses. The launcher additionally checks the full dispatch MD5. */
    int fd = open(RESET_EXECUTABLE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    for (unsigned i = 0; i < sizeof(profiles)/sizeof(profiles[0]); i++) {
        const struct reset_profile *p = &profiles[i];
        if (strcmp(model, p->model) == 0 &&
            pread(fd, words, sizeof(words), (off_t)(p->caller - 12 - 0x10000)) == sizeof(words) &&
            memcmp(words, p->words, sizeof(words)) == 0) profile = p;
    }
    close(fd);
}
static void report_armed(void)
{
    if (armed_reported) return;
    int fd = open(RESET_ARMED, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
            char pid[32];
            int n = snprintf(pid, sizeof(pid), "%ld\n", (long)getpid());
            armed_reported = write(fd, pid, n) == n;
        }
        close(fd);
    }
}

static void request_hotspot(void)
{
    char temporary[128];
    snprintf(temporary, sizeof(temporary), "%s.button.%ld", RESET_REQUEST, (long)getpid());
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (fd < 0) return;
    struct stat st;
    int ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && write(fd, "start\n", 6) == 6;
    close(fd);
    if (ok) rename(temporary, RESET_REQUEST);
    else unlink(temporary);
}
static int filter_level(int fd, ioctl_request_t request, uintptr_t caller, int result, uint64_t now)
{
    char path[64], target[64];
    if (!profile || (unsigned long)request != 0x700e || caller != profile->caller)
        return result;
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(path, target, sizeof(target)-1);
    if (n < 0) return result;
    target[n] = 0;
    if (strcmp(target, "/dev/cpld_periph") != 0) return result;
    report_armed();
    /* This exact call site is the single vendor button-poll loop. Hide every
     * pressed sample immediately, before the vendor's two-sample reset path. */
    if (now == UINT64_MAX) {
        /* Timing failure must never expose a pressed sample to factory reset. */
        press.tracking = 0;
    } else if (reset_press_update(&press, result, now)) request_hotspot();
    return result == 0 ? 1 : result;
}
int ioctl(int fd, ioctl_request_t request, ...)
{
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    int incoming_errno = errno;
    pthread_once(&once, resolve);
    if (!real_ioctl) { errno = ENOSYS; return -1; }
    errno = incoming_errno;
    int result = real_ioctl(fd, request, arg), saved = errno;
    if (profile && (unsigned long)request == 0x700e) {
        struct timespec now;
        uint64_t milliseconds = UINT64_MAX;
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
            milliseconds = (uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
        result = filter_level(fd, request, (uintptr_t)__builtin_return_address(0), result, milliseconds);
    }
    errno = saved;
    return result;
}
