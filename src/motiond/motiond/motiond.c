#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <mqueue.h>
#include <ctype.h>
#include <getopt.h>
#include "motion_tuning.h"
#include "motion_delivery.h"
#include "motion_mask.h"
#include "../../ipc_cmd/ipc_cmd/motion_metadata_levels.h"

#ifndef VE_PATH
#define VE_PATH "/sys/kernel/debug/mpp/ve"
#endif
#define BUDDY_PATH "/proc/buddyinfo"
#ifndef STATE_PATH
#define STATE_PATH "/tmp/motion.state"
#endif
#ifndef TELEMETRY_PATH
#define TELEMETRY_PATH "/tmp/motion.telemetry"
#endif
#ifndef IPC_QUEUE_NAME
#define IPC_QUEUE_NAME "/ipc_dispatch"
#endif
#define BUF_SZ 8192
#define VE_MIN_ORDER3_UNITS 4
#define VE_PRESSURE_RETRY_MS 500
#define VE_OPEN_RETRY_MS 1000

static const unsigned char IPC_MOTION_START[16] = {
    0x01,0x00,0x00,0x00, 0x02,0x00,0x00,0x00,
    0x7c,0x00,0x7c,0x00, 0x00,0x00,0x00,0x00
};
static const unsigned char IPC_MOTION_STOP[16] = {
    0x01,0x00,0x00,0x00, 0x02,0x00,0x00,0x00,
    0x7d,0x00,0x7d,0x00, 0x00,0x00,0x00,0x00
};

static volatile sig_atomic_t running = 1;
static long long ve_retry_after_ms = 0;
static int ve_uses_vmalloc = 0;

static void on_signal(int sig) {
    (void)sig;
    running = 0;
}

static long long mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

/*
 * The tested y623 VE node is non-seekable and its open callback appears to
 * require an order-3 (32 KiB with 4 KiB pages) contiguous allocation. Small
 * free pages and swap cannot satisfy that allocation when memory fragments.
 * Require four order-3 equivalents in one Normal zone (three left in reserve).
 * This is a snapshot, not a reservation: another allocator can still race us.
 * Missing, unreadable or malformed buddyinfo must never permit a VE open.
 */
static int ve_order3_reserve_ok(void) {
    char line[512];
    FILE *fp = fopen(BUDDY_PATH, "r");
    if (!fp) return 0;

    int reserve_ok = 0;
    int invalid = 0;
    while (fgets(line, sizeof(line), fp)) {
        char zone[32];
        int offset = 0;
        if (!strchr(line, '\n') ||
            sscanf(line, "Node %*u, zone %31s %n", zone, &offset) != 1 ||
            offset == 0) {
            invalid = 1;
            break;
        }
        if (strcmp(zone, "Normal") != 0) continue;

        unsigned int units = 0;
        unsigned int weight = 1;
        unsigned int order = 0;
        char *p = line + offset;
        while (*p) {
            while (isspace((unsigned char)*p)) ++p;
            if (!*p) break;
            if (!isdigit((unsigned char)*p)) {
                invalid = 1;
                break;
            }
            char *end;
            errno = 0;
            unsigned long count = strtoul(p, &end, 10);
            if (errno == ERANGE || (*end && !isspace((unsigned char)*end))) {
                invalid = 1;
                break;
            }
            if (order >= 3) {
                /* Saturate before multiplying, including on 32-bit ARM. */
                unsigned int capped = count >= VE_MIN_ORDER3_UNITS ?
                                      VE_MIN_ORDER3_UNITS : (unsigned int)count;
                units += capped * weight;
                if (units > VE_MIN_ORDER3_UNITS) units = VE_MIN_ORDER3_UNITS;
                if (weight < VE_MIN_ORDER3_UNITS) weight *= 2;
            }
            ++order;
            p = end;
        }
        if (order < 4) invalid = 1;
        if (invalid) break;
        if (units >= VE_MIN_ORDER3_UNITS) reserve_ok = 1;
    }
    if (ferror(fp)) invalid = 1;
    fclose(fp);
    return !invalid && reserve_ok;
}

/*
 * Verify the RUNNING audited y623 kernel, not the boot image on flash (which
 * may have been updated without a reboot). Read only the two VE call sites
 * from known System RAM after checking the exact kernel symbols and RAM/code
 * layout. These Thumb BL bytes are the vmalloc/vfree replacements documented
 * in scripts/patch_y623_ve_debugfs.py. No kernel/device memory is ever written.
 * Unknown layout, hidden symbols, denied/short reads or either unpatched call
 * retain the legacy guard. Cache this result once per detector invocation.
 */
static int ve_vmalloc_verified(void) {
    static const struct {
        const char *name;
        unsigned long address;
    } symbols[] = {
        {"ve_debugfs_release", 0xc018c40eUL},
        {"ve_debugfs_open",    0xc018c41eUL},
        {"vfree",             0xc0072f1cUL},
        {"vmalloc",           0xc0073198UL},
    };
    char line[256], name[128], type;
    unsigned long address;
    unsigned int seen = 0;
    FILE *fp = fopen("/proc/kallsyms", "r");
    if (!fp) return 0;
    int valid = 1;
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%lx %c %127s", &address, &type, name) != 3)
            continue;
        for (size_t i = 0; i < sizeof(symbols)/sizeof(symbols[0]); ++i) {
            if (strcmp(name, symbols[i].name) != 0) continue;
            if (address != symbols[i].address || (seen & (1U << i)))
                valid = 0;
            seen |= 1U << i;
        }
    }
    if (ferror(fp)) valid = 0;
    fclose(fp);
    if (!valid || seen != 15) return 0;

    fp = fopen("/proc/iomem", "r");
    if (!fp) return 0;
    unsigned long start, end;
    int ram = 0, code = 0;
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, " %lx-%lx : %127[^\n]", &start, &end, name) != 3)
            continue;
        if (strcmp(name, "System RAM") == 0 &&
            start == 0x40000000UL && end == 0x43ffffffUL) ram = 1;
        if (strcmp(name, "Kernel code") == 0 &&
            start == 0x40008000UL && end == 0x40357fffUL) code = 1;
    }
    valid = !ferror(fp) && ram && code;
    fclose(fp);
    if (!valid) return 0;

    int fd = open("/dev/mem", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    unsigned char alloc[4], release[4];
    static const unsigned char expected_alloc[4] = {0xe6,0xf6,0xb4,0xfe};
    static const unsigned char expected_release[4] = {0xe6,0xf6,0x82,0xfd};
    valid = pread(fd, alloc, sizeof(alloc), (off_t)0x4018c42c) == 4 &&
            pread(fd, release, sizeof(release), (off_t)0x4018c414) == 4 &&
            memcmp(alloc, expected_alloc, sizeof(alloc)) == 0 &&
            memcmp(release, expected_release, sizeof(release)) == 0;
    close(fd);
    return valid;
}

static int read_stats(struct motion_stats *s) {
    char buf[BUF_SZ];
    long long now = mono_ms();

    if (now < ve_retry_after_ms) {
        errno = EAGAIN;
        return -5;
    }

    if (!ve_uses_vmalloc && !ve_order3_reserve_ok()) {
        ve_retry_after_ms = now + VE_PRESSURE_RETRY_MS;
        errno = EAGAIN;
        return -5;
    }

    int fd = open(VE_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        ve_retry_after_ms = mono_ms() + VE_OPEN_RETRY_MS;
        return -1;
    }

    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    int saved = errno;
    close(fd);
    errno = saved;
    if (n <= 0) {
        if (n == 0) errno = EIO;
        ve_retry_after_ms = mono_ms() + VE_OPEN_RETRY_MS;
        return -1;
    }
    /* Incomplete vendor output also needs a fresh, potentially costly open. */
    ve_retry_after_ms = mono_ms() + VE_OPEN_RETRY_MS;
    buf[n] = '\0';

    /* Channel 1 (low/sub stream) may be paused when RTSP_STREAM=high. */
    /* Channel 0 stays active and is the authoritative y623 motion-stat source. */
    char *p = strstr(buf, "Channal[0]");
    if (!p) p = strstr(buf, "Channel[0]");
    if (!p) return -2;

    char *end = strstr(p, "End Channal[0]");
    if (!end) end = strstr(p, "End Channel[0]");
    if (!end) end = buf + n;

    char *line = strstr(p, "Scene:");
    if (!line || line >= end) return -3;

    struct motion_stats x = {0};
    int got = sscanf(line,
        "Scene:%d, Move:%d, MovingLevel:%d, BinImgRatio:%lf%%, MovingTh:%d",
        &x.scene, &x.move, &x.moving_level, &x.bin_ratio, &x.moving_th);
    if (got != 5) return -4;

    *s = x;
    ve_retry_after_ms = 0;
    return 0;
}

static int write_state(int active) {
    int fd = open(STATE_PATH ".tmp", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    const char *v = active ? "1\n" : "0\n";
    ssize_t wr = write(fd, v, 2);
    int saved = wr == 2 ? 0 : wr < 0 ? errno : EIO;
    if (close(fd) && !saved) saved = errno;
    if (!saved && rename(STATE_PATH ".tmp", STATE_PATH)) saved = errno;
    if (saved) unlink(STATE_PATH ".tmp");
    errno = saved;
    return saved ? -1 : 0;
}

static int parse_int_arg(const char *text, int *value) {
    if (!*text || strlen(text) > 5) return 0;
    for (const char *p = text; *p; ++p) if (!isdigit((unsigned char)*p)) return 0;
    *value = (int)strtol(text, NULL, 10);
    return 1;
}

static int parse_ratio_arg(const char *text, double *value) {
    int whole = 0, fraction = 0, dot = 0;
    for (const char *p = text; *p; ++p) {
        if (*p == '.' && !dot) { dot = 1; continue; }
        if (!isdigit((unsigned char)*p)) return 0;
        if (dot) ++fraction; else ++whole;
    }
    if (whole < 1 || whole > 3 || fraction > 2 || (dot && !fraction)) return 0;
    *value = strtod(text, NULL);
    return isfinite(*value);
}

static void settings_json(char *buffer, size_t size, const struct sens_cfg *c,
                          int interval, int custom) {
    snprintf(buffer, size, "{\"custom\":%s,\"trigger\":%.2f,\"release\":%.2f,"
        "\"confirm_samples\":%d,\"quiet_ms\":%d,\"interval_ms\":%d,"
        "\"require_zero\":%s,\"level_boost\":%s}", custom ? "true" : "false",
        c->trigger, c->release, c->confirm_samples, c->quiet_ms, interval,
        c->require_zero ? "true" : "false", c->level_boost ? "true" : "false");
}

/* Publish existing samples once per second in RAM; the web UI never opens VE.
 * Rename makes every read a complete snapshot. No video or SD-card writes. */
static void write_telemetry(const struct motion_detector *d, const struct motion_stats *s,
                            int rc, long long now, const char *settings,
                            const struct motion_delivery *ipc, int state_pending,
                            const struct motion_mask *mask) {
    char buffer[1600], sample[192], mask_json[512];
    if (mask->enabled && !mask->error) snprintf(mask_json,sizeof(mask_json),
        "{\"enabled\":true,\"error\":0,\"ratio\":%.3f,\"age_ms\":%lld,"
        "\"predicted_frame\":%s,\"source_version\":%u,\"activity\":\"%s\"}",
        mask->ratio,now-mask->frame.monotonic_ms,mask->frame.p_frame?"true":"false",
        mask->source_version,mask->activity);
    else snprintf(mask_json,sizeof(mask_json),
        "{\"enabled\":%s,\"error\":%d,\"fallback\":%s,\"ratio\":null,\"activity\":null}",
        mask->enabled?"true":"false",mask->enabled?mask->error:0,mask->fallback?"true":"false");
    if (rc == 0) snprintf(sample, sizeof(sample),
        "\"scene\":%d,\"move\":%d,\"moving_level\":%d,\"bin_ratio\":%.2f,\"moving_th\":%d",
        s->scene, s->move, s->moving_level, s->bin_ratio, s->moving_th);
    else snprintf(sample, sizeof(sample),
        "\"scene\":null,\"move\":null,\"moving_level\":null,\"bin_ratio\":null,\"moving_th\":null");
    int n = snprintf(buffer, sizeof(buffer),
        "{\"monotonic_ms\":%lld,\"active\":%s,%s,\"read_error\":%d,"
        "\"positive_samples\":%d,\"quiet_elapsed_ms\":%lld,"
        "\"ipc_pending\":%s,\"ipc_error\":%d,\"state_pending\":%s,\"effective\":%s,\"mask\":%s}\n",
        now, d->active ? "true" : "false", sample, rc, d->positives,
        d->quiet_since < 0 ? 0 : now - d->quiet_since,
        motion_delivery_pending(ipc) ? "true" : "false", ipc->error,
        state_pending ? "true" : "false", settings, mask_json);
    if (n < 0 || (size_t)n >= sizeof(buffer)) return;
    int fd = open(TELEMETRY_PATH ".tmp", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t written = write(fd, buffer, (size_t)n);
    close(fd);
    if (written == n) rename(TELEMETRY_PATH ".tmp", TELEMETRY_PATH);
}

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s [-s sensitivity_1_10] [-i interval_ms] [-a] [-r] [-k]\n"
        "  -s N   sensitivity 1..10 (default 5)\n"
        "  -i MS  poll interval 100..2000 ms (default 100)\n"
        "  -a     log every sample\n"
        "  -r     send local motion START/STOP IPC for recorder/event consumers\n"
        "  -k     report verified VE allocator and exit without sampling/events/state writes\n"
        "  --trigger PCT --release PCT  custom start/stop change ratios (0.01..100 / 0..start)\n"
        "  --confirm N --quiet-ms MS    start samples (1..50), quiet delay (100..30000)\n"
        "  --require-zero 0|1          require motion level zero while quiet\n"
        "  --settings                  print effective settings JSON and exit\n"
        "  --mask CELLS                240 row-major exclusion cells (1 ignores, 0 includes)\n"
        "  --mask-vector-pixels N      minimum vector motion 1..16 pixels (default 1)\n"
        "  --mask-difference N         intra-block temporal difference 0..255 (default 12; 0 disables)\n"
        "Default is detector-only: writes " STATE_PATH " and sends no IPC.\n", p);
}

int main(int argc, char **argv) {
    int sensitivity = 5;
    int interval_ms = 100;
    int log_all = 0;
    int record_events = 0;
    int check_kernel = 0;
    int show_settings = 0, custom = 0, valid_args = 1;
    struct sens_cfg overrides = {0};
    unsigned fields = 0;
    struct motion_mask mask={.vector_pixels=1,.difference_threshold=12};
    static const struct option options[] = {
        {"trigger", required_argument, NULL, 'T'},
        {"release", required_argument, NULL, 'R'},
        {"confirm", required_argument, NULL, 'C'},
        {"quiet-ms", required_argument, NULL, 'Q'},
        {"require-zero", required_argument, NULL, 'Z'},
        {"settings", no_argument, NULL, 'J'},
        {"mask", required_argument, NULL, 'M'},
        {"mask-vector-pixels", required_argument, NULL, 'P'},
        {"mask-difference", required_argument, NULL, 'D'},
        {NULL, 0, NULL, 0}
    };
    int opt;

    while ((opt = getopt_long(argc, argv, "s:i:arkh", options, NULL)) != -1) {
        switch (opt) {
            case 's': valid_args &= parse_int_arg(optarg, &sensitivity); break;
            case 'i': valid_args &= parse_int_arg(optarg, &interval_ms); break;
            case 'T': valid_args &= parse_ratio_arg(optarg, &overrides.trigger); fields |= 1; break;
            case 'R': valid_args &= parse_ratio_arg(optarg, &overrides.release); fields |= 2; break;
            case 'C': valid_args &= parse_int_arg(optarg, &overrides.confirm_samples); fields |= 4; break;
            case 'Q': valid_args &= parse_int_arg(optarg, &overrides.quiet_ms); fields |= 8; break;
            case 'Z': valid_args &= parse_int_arg(optarg, &overrides.require_zero); fields |= 16; break;
            case 'J': show_settings = 1; break;
            case 'M':
                valid_args &= motion_mask_valid(optarg);
                if (valid_args) {memcpy(mask.cells,optarg,sizeof(mask.cells));mask.enabled=1;}
                break;
            case 'P': valid_args &= parse_int_arg(optarg,&mask.vector_pixels); break;
            case 'D': valid_args &= parse_int_arg(optarg,&mask.difference_threshold); break;
            case 'a': log_all = 1; break;
            case 'r': record_events = 1; break;
            case 'k': check_kernel = 1; break;
            default: usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }
    if (!valid_args || optind != argc || sensitivity < 1 || sensitivity > 10 ||
        mask.vector_pixels<1 || mask.vector_pixels>16 ||
        mask.difference_threshold<0 || mask.difference_threshold>255) {
        usage(argv[0]);
        return 2;
    }

    struct sens_cfg config = cfgs[sensitivity - 1];
    if (fields & 1) config.trigger = overrides.trigger;
    if (fields & 2) config.release = overrides.release;
    if (fields & 4) config.confirm_samples = overrides.confirm_samples;
    if (fields & 8) config.quiet_ms = overrides.quiet_ms;
    if (fields & 16) config.require_zero = overrides.require_zero;
    custom = fields != 0;
    if (custom) config.level_boost = 0; /* Custom start threshold is literal. */
    if (!motion_config_valid(&config, interval_ms)) { usage(argv[0]); return 2; }
    char effective[256];
    settings_json(effective, sizeof(effective), &config, interval_ms, custom);
    if (show_settings) { puts(effective); return 0; }

    ve_uses_vmalloc = ve_vmalloc_verified();
    if (check_kernel) {
        puts(ve_uses_vmalloc ? "ve_allocator=vmalloc-verified" :
                              "ve_allocator=legacy-guard");
        return 0;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    /* Diagnostics are expendable; detection and event delivery are not.
     * The service pipes stdout/stderr to its RAM logger. Drop diagnostics if
     * that pipe is full or closed, instead of blocking the sampling loop. */
    struct stat log_stat;
    if (!fstat(STDOUT_FILENO, &log_stat) && S_ISFIFO(log_stat.st_mode)) {
        int flags = fcntl(STDOUT_FILENO, F_GETFL);
        if (flags >= 0) fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK);
    }
    setvbuf(stdout, NULL, _IONBF, 0);

    struct motion_delivery ipc;
    motion_delivery_init(&ipc, record_events, IPC_QUEUE_NAME);

    const struct sens_cfg *c = &config;
    struct motion_detector detector = {.quiet_since = -1};
    long long last_heartbeat = 0;
    long long last_telemetry = -1000;
    long long last_ipc_warning = -2000;
    long long mask_started_ms=mono_ms();
    struct motion_stats prev = {-999,-999,-999,-999.0,-999};

    int state_pending = write_state(0) != 0;
    if (state_pending) perror("write_state");
    if (motion_levels_start() != 0) perror("motion level history");

    printf("motiond v1.5.1 sens=%d trigger=%.2f release=%.2f confirm=%d quiet_ms=%d interval_ms=%d record_events=%d ve_allocator=%s custom=%d require_zero=%d mask=%d\n",
           sensitivity, c->trigger, c->release, c->confirm_samples,
           c->quiet_ms, interval_ms, record_events,
           ve_uses_vmalloc ? "vmalloc-verified" : "legacy-guard", custom, c->require_zero,mask.enabled);
    fflush(stdout);

    while (running) {
        clearerr(stdout);
        clearerr(stderr);
        struct motion_stats s = {0};
        int rc = read_stats(&s);
        long long now = mono_ms();
        if (rc == 0 && (!isfinite(s.bin_ratio) || s.bin_ratio < 0 ||
                        s.bin_ratio > 100 || s.moving_level < 0)) rc = -5;
        struct motion_stats spatial=s;
        struct sens_cfg detection_config=*c;
        int skip_update=0, detection_valid=rc==0;
        if (mask.enabled) {
            int map_rc=motion_mask_read(&mask,now);
            mask.fallback=map_rc<0 && (mask.last_pid || now-mask_started_ms>=1000);
            if (map_rc>=0) {
                skip_update=map_rc==0;
                spatial.bin_ratio=mask.ratio;
                spatial.moving_level=mask.ratio<=c->release?0:1;
                detection_config.level_boost=0;
            }
            else if (!mask.fallback) detection_valid=0;
            /* An unavailable spatial source falls back to the whole-frame
             * detector, explicitly reported in telemetry/UI. Never silently
             * lose recording because an optional publisher failed. */
        }
        int transition=skip_update?0:motion_update(&detector,&detection_config,detection_valid?&spatial:NULL,now);
        // Capture the triggering reading before IPC/logging can delay its time.
        int capture = motion_levels_due(detector.active, transition > 0, now);
        if (capture || now - last_telemetry >= 1000) {
            struct timespec wall;
            if (clock_gettime(CLOCK_REALTIME, &wall) == 0) {
                struct motion_level_sample raw = {
                    .unix_ms = (int64_t)wall.tv_sec * 1000 + wall.tv_nsec / 1000000,
                    .scene = s.scene, .move = s.move, .moving_level = s.moving_level,
                    .bin_ratio = s.bin_ratio, .moving_th = s.moving_th
                };
                motion_levels_tick(capture && detector.active, rc == 0, &raw, now);
            }
        }
        if (transition) {
            state_pending = write_state(detector.active) != 0;
            if (state_pending) perror("write_state");
            motion_delivery_want(&ipc, detector.active);
        }
        if (motion_delivery_tick(&ipc, now, IPC_MOTION_START, IPC_MOTION_STOP) &&
            now - last_ipc_warning >= 2000) {
            perror("motion IPC pending");
            last_ipc_warning = now;
        }
        if (transition) {
            printf("t=%lld MOTION %s bin=%.2f level=%d move=%d%s\n", now,
                detector.active ? "ON" : "OFF", s.bin_ratio, s.moving_level, s.move,
                record_events ? (detector.active ? " IPC=START" : " IPC=STOP") : "");
            fflush(stdout);
        }
        if (now - last_telemetry >= 1000) {
            if (state_pending) state_pending = write_state(detector.active) != 0;
            write_telemetry(&detector, &s, rc, now, effective, &ipc, state_pending,&mask);
            last_telemetry = now;
        }

        if (rc == 0) {
            int changed =
                s.scene != prev.scene ||
                s.move != prev.move ||
                s.moving_level != prev.moving_level ||
                s.moving_th != prev.moving_th ||
                s.bin_ratio != prev.bin_ratio;

            if (log_all || changed || now - last_heartbeat >= 2000) {
                printf("t=%lld state=%d sens=%d scene=%d move=%d level=%d bin=%.2f th=%d%s\n",
                       now, detector.active, sensitivity, s.scene, s.move, s.moving_level,
                       s.bin_ratio, s.moving_th, changed ? " *" : "");
                fflush(stdout);
                last_heartbeat = now;
            }
            prev = s;
        } else {
            /* Missing samples establish neither motion nor a quiet period. */
            if (now - last_heartbeat >= 2000) {
                fprintf(stderr, "t=%lld read_error=%d errno=%d\n", now, rc, errno);
                fflush(stderr);
                last_heartbeat = now;
            }
        }

        struct timespec req;
        req.tv_sec = interval_ms / 1000;
        req.tv_nsec = (long)(interval_ms % 1000) * 1000000L;
        nanosleep(&req, NULL);
    }

    /* Service shutdown is bounded even if the broker is unavailable. A later
     * startup/reconnection resets stale recorder motion before sending START. */
    motion_delivery_want(&ipc, 0);
    for (int attempt = 0; attempt < 5 && motion_delivery_pending(&ipc); ++attempt) {
        motion_delivery_tick(&ipc, mono_ms(), IPC_MOTION_START, IPC_MOTION_STOP);
        if (motion_delivery_pending(&ipc)) {
            struct timespec retry = {.tv_nsec = 100000000};
            nanosleep(&retry, NULL);
        }
    }
    if (motion_delivery_pending(&ipc)) fprintf(stderr, "motion IPC STOP not delivered before shutdown\n");
    write_state(0);
    unlink(TELEMETRY_PATH);
    motion_delivery_close(&ipc);
    motion_mask_close(&mask);
    printf("motiond stopped\n");
    return 0;
}
