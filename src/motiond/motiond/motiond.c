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

#define VE_PATH "/sys/kernel/debug/mpp/ve"
#define BUDDY_PATH "/proc/buddyinfo"
#define STATE_PATH "/tmp/motion.state"
#define IPC_QUEUE_NAME "/ipc_dispatch"
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

struct motion_stats {
    int scene;
    int move;
    int moving_level;
    double bin_ratio;
    int moving_th;
};

struct sens_cfg {
    double trigger;
    double release;
    int confirm_samples;
    int quiet_ms;
};

static const struct sens_cfg cfgs[10] = {
    {15.00, 1.50, 5, 2000},
    {10.00, 1.00, 5, 2000},
    { 7.00, 0.70, 4, 2000},
    { 5.00, 0.50, 4, 2000},
    { 3.00, 0.30, 3, 2000},
    { 2.00, 0.20, 3, 2000},
    { 1.20, 0.15, 3, 2000},
    { 0.80, 0.15, 2, 2000},
    { 0.50, 0.15, 2, 2000},
    { 0.25, 0.15, 2, 2000},
};

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

static int read_stats(struct motion_stats *s) {
    char buf[BUF_SZ];
    long long now = mono_ms();

    if (now < ve_retry_after_ms) {
        errno = EAGAIN;
        return -5;
    }

    if (!ve_order3_reserve_ok()) {
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

    char *p = strstr(buf, "Channal[1]");
    if (!p) p = strstr(buf, "Channel[1]");
    if (!p) return -2;

    char *end = strstr(p, "End Channal[1]");
    if (!end) end = strstr(p, "End Channel[1]");
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
    int fd = open(STATE_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    const char *v = active ? "1\n" : "0\n";
    ssize_t wr = write(fd, v, 2);
    int saved = errno;
    close(fd);
    errno = saved;
    return wr == 2 ? 0 : -1;
}

static int send_motion_ipc(mqd_t mq, int active) {
    const unsigned char *msg = active ? IPC_MOTION_START : IPC_MOTION_STOP;
    return mq_send(mq, (const char *)msg, 16, 0);
}

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s [-s sensitivity_1_10] [-i interval_ms] [-a] [-r]\n"
        "  -s N   sensitivity 1..10 (default 5)\n"
        "  -i MS  poll interval 100..2000 ms (default 100)\n"
        "  -a     log every sample\n"
        "  -r     send local motion START/STOP IPC for recorder/event consumers\n"
        "Default is detector-only: writes " STATE_PATH " and sends no IPC.\n", p);
}

int main(int argc, char **argv) {
    int sensitivity = 5;
    int interval_ms = 100;
    int log_all = 0;
    int record_events = 0;
    int opt;

    while ((opt = getopt(argc, argv, "s:i:arh")) != -1) {
        switch (opt) {
            case 's': sensitivity = atoi(optarg); break;
            case 'i': interval_ms = atoi(optarg); break;
            case 'a': log_all = 1; break;
            case 'r': record_events = 1; break;
            default: usage(argv[0]); return opt == 'h' ? 0 : 2;
        }
    }
    if (sensitivity < 1 || sensitivity > 10 ||
        interval_ms < 100 || interval_ms > 2000) {
        usage(argv[0]);
        return 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    mqd_t mq = (mqd_t)-1;
    if (record_events) {
        mq = mq_open(IPC_QUEUE_NAME, O_RDWR);
        if (mq == (mqd_t)-1) {
            perror("mq_open " IPC_QUEUE_NAME);
            return 1;
        }
    }

    const struct sens_cfg *c = &cfgs[sensitivity - 1];
    int active = 0;
    int positives = 0;
    long long quiet_since = -1;
    long long last_heartbeat = 0;
    struct motion_stats prev = {-999,-999,-999,-999.0,-999};

    if (write_state(0) != 0) {
        perror("write_state");
        if (mq != (mqd_t)-1) mq_close(mq);
        return 1;
    }

    printf("motiond v1.1 sens=%d trigger=%.2f release=%.2f confirm=%d quiet_ms=%d interval_ms=%d record_events=%d\n",
           sensitivity, c->trigger, c->release, c->confirm_samples,
           c->quiet_ms, interval_ms, record_events);
    fflush(stdout);

    while (running) {
        struct motion_stats s;
        int rc = read_stats(&s);
        long long now = mono_ms();

        if (rc == 0) {
            int changed =
                s.scene != prev.scene ||
                s.move != prev.move ||
                s.moving_level != prev.moving_level ||
                s.moving_th != prev.moving_th ||
                s.bin_ratio != prev.bin_ratio;

            int strong = (s.bin_ratio >= c->trigger) ||
                         (s.moving_level >= 2 && s.bin_ratio >= c->trigger * 0.5);

            if (!active) {
                if (strong) positives++;
                else positives = 0;

                if (positives >= c->confirm_samples) {
                    active = 1;
                    quiet_since = -1;
                    if (write_state(1) != 0) perror("write_state");
                    if (record_events && send_motion_ipc(mq, 1) != 0)
                        perror("mq_send START");
                    printf("t=%lld MOTION ON bin=%.2f level=%d move=%d%s\n",
                           now, s.bin_ratio, s.moving_level, s.move,
                           record_events ? " IPC=START" : "");
                    fflush(stdout);
                }
            } else {
                int quiet = (s.bin_ratio <= c->release && s.moving_level == 0);
                if (quiet) {
                    if (quiet_since < 0) quiet_since = now;
                    if (now - quiet_since >= c->quiet_ms) {
                        active = 0;
                        positives = 0;
                        if (write_state(0) != 0) perror("write_state");
                        if (record_events && send_motion_ipc(mq, 0) != 0)
                            perror("mq_send STOP");
                        printf("t=%lld MOTION OFF bin=%.2f level=%d move=%d quiet=%lldms%s\n",
                               now, s.bin_ratio, s.moving_level, s.move,
                               now - quiet_since,
                               record_events ? " IPC=STOP" : "");
                        fflush(stdout);
                    }
                } else {
                    quiet_since = -1;
                }
            }

            if (log_all || changed || now - last_heartbeat >= 2000) {
                printf("t=%lld state=%d sens=%d scene=%d move=%d level=%d bin=%.2f th=%d%s\n",
                       now, active, sensitivity, s.scene, s.move, s.moving_level,
                       s.bin_ratio, s.moving_th, changed ? " *" : "");
                fflush(stdout);
                last_heartbeat = now;
            }
            prev = s;
        } else {
            /* Missing samples establish neither motion nor a quiet period. */
            positives = 0;
            quiet_since = -1;
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

    if (active && record_events && mq != (mqd_t)-1) {
        if (send_motion_ipc(mq, 0) != 0) perror("mq_send STOP");
    }
    write_state(0);
    if (mq != (mqd_t)-1) mq_close(mq);
    printf("motiond stopped\n");
    return 0;
}
