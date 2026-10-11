#define _GNU_SOURCE
#include "nightvision.h"
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Exact audited, non-PIE ARM builds. The launcher additionally checks MD5. */
struct nv_profile {
    const char *model;
    uintptr_t loop_call, loop_func, level_call, level_func, context;
    uintptr_t committed_state, cycle_guard;
    uint32_t loop_instruction, level_instruction;
};
static const struct nv_profile profiles[] = {
    {"y623", 0x25808, 0x23e50, 0x23f10, 0x4f390, 0x23a2e4, 0x224800, 0x2247ec,
     0xebfff990, 0xeb00ad1e},
    {"y28ga", 0x34ce8, 0x333e8, 0x33518, 0x5685c, 0x23f6ec, 0x23bf2c, 0x23bf1c,
     0xebfff9be, 0xeb008ccf}
};
static const struct nv_profile *profile;
static struct nv_control *control;
static unsigned active_mode, active_threshold = 50, active_generation;
static int last_level = -1, last_effective = -1;

static unsigned monotonic_seconds(void)
{
    struct timespec now;
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0 ? (unsigned)now.tv_sec : 0;
}

static void read_settings(void)
{
    for (int attempt = 0; attempt < 4; ++attempt) {
        unsigned first = __atomic_load_n(&control->generation, __ATOMIC_ACQUIRE);
        if (first & 1) continue;
        unsigned mode = __atomic_load_n(&control->mode, __ATOMIC_RELAXED);
        unsigned threshold = __atomic_load_n(&control->threshold, __ATOMIC_RELAXED);
        unsigned last = __atomic_load_n(&control->generation, __ATOMIC_ACQUIRE);
        if (first != last || mode > NV_OFF || threshold < 1 || threshold > 100)
            continue;
        active_mode = mode;
        active_threshold = threshold;
        active_generation = first;
        return;
    }
    /* A writer cannot stall the native camera loop. Keep the last good pair. */
}

static int camera_light_level(int isp)
{
    int (*native_level)(int) = (void *)profile->level_func;
    last_level = native_level(isp);
    last_effective = nv_level(last_level, active_mode, active_threshold);
    return last_effective;
}

static void camera_nightvision_loop(void)
{
    unsigned previous_generation = active_generation;
    read_settings();
    /* g_rmm_info is the exported context OBJECT itself, not a pointer slot. */
    uintptr_t ctx = profile->context;
    if (ctx && active_mode != NV_AUTO) {
        /* An explicit manual command must also work after the firmware has
         * locked automatic switching following repeated light fluctuations.
         * Leave that native counter/delay untouched during Automatic mode. */
        if (active_generation != previous_generation)
            *(int32_t *)profile->cycle_guard = 0;
        /* The original loop still performs its complete ISP/IR-cut/IR LED,
         * encoder and (y28ga) IVA transition. The light-level hook holds the
         * requested state instead of allowing the automatic decision to undo it.
         * Never manipulate GPIOs from a second process. */
        *(int32_t *)(ctx + 0xac) = active_mode == NV_ON;
    }
    void (*native_loop)(void) = (void *)profile->loop_func;
    native_loop();
    __atomic_store_n(&control->light_level, last_level, __ATOMIC_RELAXED);
    __atomic_store_n(&control->effective_level, last_effective, __ATOMIC_RELAXED);
    int state = *(int32_t *)profile->committed_state;
    __atomic_store_n(&control->state, state, __ATOMIC_RELAXED);
    __atomic_store_n(&control->applied_generation, active_generation, __ATOMIC_RELEASE);
    __atomic_store_n(&control->heartbeat, monotonic_seconds(), __ATOMIC_RELEASE);
}

#ifdef __arm__
static int branch_instruction(uintptr_t site, uintptr_t target, uint32_t *word)
{
    int64_t offset = (int64_t)target - (int64_t)site - 8;
    if ((offset & 3) || offset < -33554432 || offset > 33554428) return -1;
    *word = 0xeb000000 | ((uint32_t)(offset >> 2) & 0xffffff);
    return 0;
}

static int replace_call(uintptr_t site, uint32_t word, long page_size)
{
    uintptr_t page = site & ~((uintptr_t)page_size - 1);
    if (mprotect((void *)page, page_size, PROT_READ | PROT_WRITE | PROT_EXEC))
        return -1;
    __atomic_store_n((uint32_t *)site, word, __ATOMIC_RELEASE);
    __builtin___clear_cache((char *)site, (char *)(site + 4));
    return mprotect((void *)page, page_size, PROT_READ | PROT_EXEC);
}

__attribute__((constructor)) static void initialize_nightvision(void)
{
    const char *model = getenv("YI_NIGHTVISION_MODEL");
    char exe[80];
    ssize_t len = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (len < 0) return;
    exe[len] = 0;
    if (strcmp(exe, "/home/app/rmm")) return;
    for (unsigned i = 0; model && i < sizeof(profiles) / sizeof(profiles[0]); ++i)
        if (!strcmp(model, profiles[i].model)) profile = &profiles[i];
    if (!profile) return;

    int fd = open(NV_PATH, O_RDWR | O_CLOEXEC);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) || st.st_size != sizeof(*control)) { close(fd); return; }
    control = mmap(NULL, sizeof(*control), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (control == MAP_FAILED) { control = NULL; return; }
    if (control->magic != NV_MAGIC || control->version != NV_VERSION) return;
    control->ready_pid = 0;
    control->error = 1;
    if (*(uint32_t *)profile->loop_call != profile->loop_instruction ||
        *(uint32_t *)profile->level_call != profile->level_instruction) return;

    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size < 1) return;
    /* A non-fixed hint never replaces an existing camera mapping. Two ARM
     * veneers bridge the short BL range to the dynamically loaded library. */
    uint32_t *bridge = mmap((void *)0x400000, page_size, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (bridge == MAP_FAILED) return;
    uint32_t loop_branch, level_branch;
    if (branch_instruction(profile->loop_call, (uintptr_t)bridge, &loop_branch) ||
        branch_instruction(profile->level_call, (uintptr_t)(bridge + 2), &level_branch)) {
        munmap(bridge, page_size);
        return;
    }
    bridge[0] = bridge[2] = 0xe51ff004; /* ldr pc, [pc, #-4] */
    bridge[1] = (uintptr_t)camera_nightvision_loop;
    bridge[3] = (uintptr_t)camera_light_level;
    __builtin___clear_cache((char *)bridge, (char *)(bridge + 4));
    if (mprotect(bridge, page_size, PROT_READ | PROT_EXEC)) {
        munmap(bridge, page_size);
        return;
    }
    if (replace_call(profile->level_call, level_branch, page_size)) {
        replace_call(profile->level_call, profile->level_instruction, page_size);
        /* A failed RX restore may still have installed the call. Retain the
         * veneer so even a failed rollback cannot leave a dangling target. */
        return;
    }
    if (replace_call(profile->loop_call, loop_branch, page_size)) {
        replace_call(profile->loop_call, profile->loop_instruction, page_size);
        replace_call(profile->level_call, profile->level_instruction, page_size);
        return;
    }
    control->error = 0;
    __atomic_store_n(&control->ready_pid, getpid(), __ATOMIC_RELEASE);
}
#endif
