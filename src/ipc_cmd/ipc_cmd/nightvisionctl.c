#define _GNU_SOURCE
#include "nightvision.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static unsigned seconds(void)
{
    struct timespec t;
    return clock_gettime(CLOCK_MONOTONIC, &t) == 0 ? (unsigned)t.tv_sec : 0;
}

int main(int argc, char **argv)
{
    unsigned mode = NV_AUTO, threshold = 50;
    int writing = argc == 4 && (!strcmp(argv[1], "--set") || !strcmp(argv[1], "--init"));
    if (!writing && !(argc == 2 && !strcmp(argv[1], "--status"))) return 2;
    if (writing) {
        if (!strcmp(argv[2], "on")) mode = NV_ON;
        else if (!strcmp(argv[2], "off")) mode = NV_OFF;
        else if (strcmp(argv[2], "auto")) return 2;
        char *end;
        errno = 0;
        long value = strtol(argv[3], &end, 10);
        if (errno || !*argv[3] || *end || value < 1 || value > 100) return 2;
        threshold = value;
    }
    int initializing = writing && !strcmp(argv[1], "--init");
    int fd = open(NV_PATH, O_RDWR | O_CLOEXEC | (initializing ? O_CREAT : 0), 0600);
    if (fd < 0) {
        puts("{\"error\":false,\"supported\":false,\"state\":\"unavailable\"}");
        return writing ? 1 : 0;
    }
    struct stat st;
    if (fstat(fd, &st) || (st.st_size != sizeof(struct nv_control) &&
        (!initializing || ftruncate(fd, sizeof(struct nv_control))))) { close(fd); return 1; }
    struct nv_control *c = mmap(NULL, sizeof(*c), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (c == MAP_FAILED) { close(fd); return 1; }
    if (c->magic != NV_MAGIC || c->version != NV_VERSION) {
        if (!initializing) { munmap(c, sizeof(*c)); close(fd); return 1; }
        memset(c, 0, sizeof(*c));
        c->version = NV_VERSION;
        c->threshold = 50;
        c->state = c->light_level = c->effective_level = -1;
        c->magic = NV_MAGIC;
    }
    if (writing) {
        /* These camera kernels have no flock syscall. A bounded atomic writer
         * lock also lets the native reader avoid syscalls and blocking waits. */
        unsigned generation = 0;
        int locked = 0;
        for (int attempt = 0; attempt < 50; ++attempt) {
            generation = __atomic_load_n(&c->generation, __ATOMIC_ACQUIRE);
            if (!(generation & 1) && __atomic_compare_exchange_n(&c->generation,
                    &generation, generation + 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                locked = 1;
                break;
            }
            usleep(1000);
        }
        if (!locked) { munmap(c, sizeof(*c)); close(fd); return 1; }
        __atomic_store_n(&c->mode, mode, __ATOMIC_RELAXED);
        __atomic_store_n(&c->threshold, threshold, __ATOMIC_RELAXED);
        __atomic_store_n(&c->generation, generation + 2, __ATOMIC_RELEASE);
    }
    unsigned generation = 0;
    int snapshot = 0;
    for (int attempt = 0; attempt < 50; ++attempt) {
        generation = __atomic_load_n(&c->generation, __ATOMIC_ACQUIRE);
        if (!(generation & 1)) {
            mode = __atomic_load_n(&c->mode, __ATOMIC_RELAXED);
            threshold = __atomic_load_n(&c->threshold, __ATOMIC_RELAXED);
            if (generation == __atomic_load_n(&c->generation, __ATOMIC_ACQUIRE)) {
                snapshot = 1;
                break;
            }
        }
        usleep(1000);
    }
    if (!snapshot) { munmap(c, sizeof(*c)); close(fd); return 1; }
    unsigned pid = __atomic_load_n(&c->ready_pid, __ATOMIC_ACQUIRE);
    unsigned age = seconds() - __atomic_load_n(&c->heartbeat, __ATOMIC_ACQUIRE);
    int supported = pid && !c->error && kill(pid, 0) == 0;
    int applied = supported && age < 5 && c->applied_generation == generation &&
        (mode == NV_AUTO || (mode == NV_ON && c->state == 1) ||
         (mode == NV_OFF && c->state == 0));
    const char *modes[] = {"auto", "on", "off"};
    const char *state = !supported || age >= 5 ? "unavailable" :
        c->state == 1 ? "night" : c->state == 0 ? "day" : "unknown";
    printf("{\"error\":false,\"supported\":%s,\"mode\":\"%s\",\"threshold\":%u,"
           "\"state\":\"%s\",\"applied\":%s,\"light_level\":%d,\"effective_level\":%d,\"pid\":%u}\n",
           supported ? "true" : "false", modes[mode <= NV_OFF ? mode : 0],
           threshold, state, applied ? "true" : "false", c->light_level, c->effective_level, pid);
    munmap(c, sizeof(*c));
    close(fd);
    return writing && !strcmp(argv[1], "--set") && !supported ? 1 : 0;
}
