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
#include <sys/stat.h>

#define VE_PATH "/sys/kernel/debug/mpp/ve"
#define IPC_QUEUE "/ipc_dispatch"
#define STATE_PATH "/tmp/motion.state"
#define BUF_SZ 8192

static volatile sig_atomic_t running = 1;

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
    int confirm;
    int quiet_ms;
};

static const struct sens_cfg cfgs[10] = {
    {15.00, 1.00, 4, 2500},
    {10.00, 0.80, 4, 2500},
    { 7.00, 0.60, 3, 2500},
    { 5.00, 0.40, 3, 2250},
    { 3.00, 0.20, 3, 2000},
    { 2.00, 0.18, 3, 2000},
    { 1.20, 0.15, 2, 2000},
    { 0.80, 0.12, 2, 2000},
    { 0.50, 0.10, 2, 2000},
    { 0.25, 0.08, 2, 2000}
};

static const unsigned char IPC_MOTION_START[16] = {
    0x01,0x00,0x00,0x00,0x02,0x00,0x00,0x00,
    0x7c,0x00,0x7c,0x00,0x00,0x00,0x00,0x00
};
static const unsigned char IPC_MOTION_STOP[16] = {
    0x01,0x00,0x00,0x00,0x02,0x00,0x00,0x00,
    0x7d,0x00,0x7d,0x00,0x00,0x00,0x00,0x00
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

static int read_stats(struct motion_stats *s) {
    char buf[BUF_SZ];
    int fd = open(VE_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    int saved = errno;
    close(fd);
    errno = saved;
    if (n <= 0) return -1;
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
    return 0;
}

static int write_state(int active) {
    int fd = open(STATE_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    const char *v = active ? "1\n" : "0\n";
    ssize_t n = write(fd, v, 2);
    close(fd);
    return n == 2 ? 0 : -1;
}

static int send_ipc(mqd_t mq, int active) {
    if (mq == (mqd_t)-1) return -1;
    const unsigned char *msg = active ? IPC_MOTION_START : IPC_MOTION_STOP;
    return mq_send(mq, (const char *)msg, 16, 0);
}

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s [-s 1..10] [-i interval_ms] [-R] [-a]\n"
        "  -s N  sensitivity 1..10 (default 5)\n"
        "  -i MS poll interval 100..2000 ms (default 250)\n"
        "  -R    send local motion start/stop IPC for recording\n"
        "  -a    log every sample\n", p);
}

int main(int argc, char **argv) {
    int sensitivity = 5;
    int interval_ms = 250;
    int record = 0;
    int log_all = 0;
    int opt;

    while ((opt = getopt(argc, argv, "s:i:Rah")) != -1) {
        switch (opt) {
            case 's': sensitivity = atoi(optarg); break;
            case 'i': interval_ms = atoi(optarg); break;
            case 'R': record = 1; break;
            case 'a': log_all = 1; break;
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

    const struct sens_cfg *c = &cfgs[sensitivity - 1];
    mqd_t mq = (mqd_t)-1;
    if (record) {
        mq = mq_open(IPC_QUEUE, O_RDWR);
        if (mq == (mqd_t)-1) {
            fprintf(stderr, "motiond: cannot open %s errno=%d\n", IPC_QUEUE, errno);
            return 3;
        }
    }

    int active = 0;
    int positives = 0;
    long long quiet_since = -1;
    long long last_heartbeat = 0;
    struct motion_stats prev = {-999,-999,-999,-999.0,-999};

    write_state(0);
    printf("motiond v0.2 sens=%d trigger=%.2f release=%.2f confirm=%d quiet_ms=%d interval_ms=%d record=%d\n",
           sensitivity, c->trigger, c->release, c->confirm, c->quiet_ms, interval_ms, record);
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

            int strong =
                (s.bin_ratio >= c->trigger) ||
                (s.moving_level >= 2 && s.bin_ratio >= c->trigger * 0.5);

            if (!active) {
                if (strong) positives++;
                else positives = 0;

                if (positives >= c->confirm) {
                    active = 1;
                    positives = 0;
                    quiet_since = -1;
                    write_state(1);
                    if (record && send_ipc(mq, 1) != 0)
                        fprintf(stderr, "motiond: IPC start failed errno=%d\n", errno);
                    printf("t=%lld MOTION ON bin=%.2f level=%d move=%d\n",
                           now, s.bin_ratio, s.moving_level, s.move);
                    fflush(stdout);
                }
            } else {
                int quiet = (s.moving_level == 0 && s.bin_ratio <= c->release);
                if (quiet) {
                    if (quiet_since < 0) quiet_since = now;
                    if (now - quiet_since >= c->quiet_ms) {
                        active = 0;
                        quiet_since = -1;
                        positives = 0;
                        write_state(0);
                        if (record && send_ipc(mq, 0) != 0)
                            fprintf(stderr, "motiond: IPC stop failed errno=%d\n", errno);
                        printf("t=%lld MOTION OFF bin=%.2f level=%d move=%d\n",
                               now, s.bin_ratio, s.moving_level, s.move);
                        fflush(stdout);
                    }
                } else {
                    quiet_since = -1;
                }
            }

            if (log_all || changed || now - last_heartbeat >= 5000) {
                printf("t=%lld state=%d sens=%d scene=%d move=%d level=%d bin=%.2f th=%d%s\n",
                       now, active, sensitivity, s.scene, s.move, s.moving_level,
                       s.bin_ratio, s.moving_th, changed ? " *" : "");
                fflush(stdout);
                last_heartbeat = now;
            }
            prev = s;
        } else if (now - last_heartbeat >= 5000) {
            fprintf(stderr, "t=%lld read_error=%d errno=%d\n", now, rc, errno);
            fflush(stderr);
            last_heartbeat = now;
        }

        struct timespec req;
        req.tv_sec = interval_ms / 1000;
        req.tv_nsec = (long)(interval_ms % 1000) * 1000000L;
        nanosleep(&req, NULL);
    }

    if (active) {
        write_state(0);
        if (record) send_ipc(mq, 0);
    }
    if (mq != (mqd_t)-1) mq_close(mq);

    printf("motiond stopped\n");
    return 0;
}
