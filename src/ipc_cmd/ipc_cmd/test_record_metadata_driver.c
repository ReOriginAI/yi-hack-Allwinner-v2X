// SPDX-License-Identifier: GPL-3.0-only
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <assert.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include "motion_metadata_events.h"
#include "motion_metadata_levels.h"
#include "ipc2file.h"

extern void (**ipc_callbacks)(void *);
extern int parse_message(char *, ssize_t);

int main(int argc, char **argv) {
    assert(argc == 4);
    char output[4096];
    snprintf(output, sizeof output, "%s/tmp.mp4.tmp", argv[1]);
    int input = open(argv[2], O_RDONLY);
    assert(input >= 0);
    int fd = open(output, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    assert(fd >= 0);
    char buffer[4096];
    ssize_t n;
    while ((n = read(input, buffer, sizeof buffer)) > 0) {
        ssize_t copied = 0;
        while (copied < n) {
            ssize_t written = write(fd, buffer + copied, n - copied);
            assert(written > 0);
            copied += written;
        }
    }
    assert(n == 0);
    close(input);
    assert(motion_history_start() == 0);
    assert(motion_levels_start() == 0);
    ipc_callbacks = calloc(IPC_MSG_LAST, sizeof(*ipc_callbacks));
    assert(ipc_callbacks);
    if (!strcmp(argv[3], "events")) {
        char queue_name[64];
        snprintf(queue_name, sizeof queue_name, "/yi-metadata-test-%d", getpid());
        struct mq_attr attr = {.mq_maxmsg=4, .mq_msgsize=32};
        mqd_t queue = mq_open(queue_name, O_CREAT|O_EXCL|O_RDWR, 0600, &attr);
        assert(queue != (mqd_t)-1);
        unsigned char msg[16] = {1,0,0,0,2,0,0,0,0x7c,0,0x7c,0,0,0,0,0};
        for (int event = 0; event < 5; ++event) {
            // Establish idle even when the real camera is already active.
            if (event == 0 || event == 4) msg[8] = msg[10] = 0x7d;
            if (event == 1 || event == 2) msg[8] = msg[10] = 0x7c;
            if (event == 3) msg[8] = msg[10] = 0xed; // Ignore classifier.
            assert(mq_send(queue, (char *)msg, sizeof msg, 0) == 0);
            assert(mq_receive(queue, buffer, sizeof buffer, NULL) == sizeof msg);
            assert(parse_message(buffer, sizeof msg) == 0);
            usleep(20000);
        }
        mq_close(queue); mq_unlink(queue_name);
        int64_t wall = motion_wall_ms();
        struct motion_level_sample raw = {.unix_ms=wall, .scene=2, .move=4,
            .moving_level=1, .bin_ratio=1, .moving_th=20};
        motion_levels_tick(0, 1, &raw, 1000); // Idle samples are omitted.
        raw.unix_ms=wall+1000; raw.bin_ratio=3.25; raw.moving_level=2;
        motion_levels_tick(1, 1, &raw, 2000);
        raw.unix_ms=wall+2000;
        motion_levels_tick(1, 0, &raw, 3000); // Invalid readings are omitted.
        raw.unix_ms=wall+3000; raw.bin_ratio=8.5; raw.moving_level=3;
        motion_levels_tick(1, 1, &raw, 4000);
    } else if (!strcmp(argv[3], "no-space")) {
        struct stat st;
        assert(fstat(fd, &st) == 0);
        struct rlimit limit = {.rlim_cur=st.st_size, .rlim_max=st.st_size};
        signal(SIGXFSZ, SIG_IGN);
        assert(setrlimit(RLIMIT_FSIZE, &limit) == 0);
    }
    // The audited muxers rewrite mdat's size and close from offset 36.
    assert(lseek(fd, 36, SEEK_SET) == 36);
    assert(close(fd) == 0);
    struct stat before, after;
    assert(stat(output, &before) == 0);
    fd = open(output, O_RDWR); // Existing videos are outside the annotation scope.
    assert(fd >= 0 && close(fd) == 0);
    assert(stat(output, &after) == 0 && before.st_size == after.st_size);
    free(ipc_callbacks);
    return 0;
}
