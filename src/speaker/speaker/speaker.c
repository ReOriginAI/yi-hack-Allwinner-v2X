#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DEVICE_NUM 0x70
#define CPLD_DEV "/dev/cpld_periph"
#define AUDIO_FIFO "/tmp/audio_in_fifo"
#define SEM_FILE "audio_in_fifo.lock"

static volatile sig_atomic_t stop_requested = 0;

static void handle_signal(int signo) {
    (void)signo;
    stop_requested = 1;
}

static int install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);

    if (sigaction(SIGTERM, &sa, NULL) < 0) return -1;
    if (sigaction(SIGINT, &sa, NULL) < 0) return -1;
    if (sigaction(SIGHUP, &sa, NULL) < 0) return -1;
    return 0;
}

static int open_cpld(void) {
    if (access(CPLD_DEV, F_OK) != 0) return -1;
    return open(CPLD_DEV, O_RDWR);
}

static void run_io(int fd, int n) {
    ioctl(fd, _IOC(0, DEVICE_NUM, n, 0x00), 0);
}

static int switch_speaker(int on) {
    int fd = open_cpld();
    if (fd < 0) {
        fprintf(stderr, "Error: cannot open %s\n", CPLD_DEV);
        return -1;
    }

    run_io(fd, on ? 16 : 17);
    close(fd);
    return 0;
}

static int16_t linear16_from_ulaw(unsigned char uLawByte) {
    static const int exp_lut[8] = {0, 132, 396, 924, 1980, 4092, 8316, 16764};
    int sign;
    unsigned char exponent;
    unsigned char mantissa;
    int result;

    uLawByte = (unsigned char)~uLawByte;
    sign = (uLawByte & 0x80) != 0;
    exponent = (uLawByte >> 4) & 0x07;
    mantissa = uLawByte & 0x0F;
    result = exp_lut[exponent] + (mantissa << (exponent + 3));

    return (int16_t)(sign ? -result : result);
}

static int write_all(int fd, const void *buf, size_t count) {
    const unsigned char *p = (const unsigned char *)buf;

    while (count > 0 && !stop_requested) {
        ssize_t n = write(fd, p, count);
        if (n > 0) {
            p += n;
            count -= (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        return -1;
    }

    return count == 0 ? 0 : -1;
}

static int stream_pcm(const char *format) {
    unsigned char input[1024];
    int16_t pcm[2048];
    sem_t *sem = SEM_FAILED;
    int fifo = -1;
    int speaker_on = 0;
    int rc = 1;

    if (strcmp(format, "ulaw") != 0 && strcmp(format, "pcm") != 0) {
        fprintf(stderr, "Unsupported stream format: %s\n", format);
        return 2;
    }

    if (install_signal_handlers() < 0) {
        perror("sigaction");
        return 1;
    }

    sem = sem_open(SEM_FILE, O_CREAT, 0644, 1);
    if (sem == SEM_FAILED) {
        perror("sem_open");
        return 1;
    }

    if (sem_trywait(sem) < 0) {
        fprintf(stderr, "Speaker is busy\n");
        goto cleanup;
    }

    fifo = open(AUDIO_FIFO, O_WRONLY);
    if (fifo < 0) {
        if (!stop_requested) perror("open audio fifo");
        goto unlock;
    }

    if (switch_speaker(1) < 0) goto unlock;
    speaker_on = 1;

    while (!stop_requested) {
        ssize_t n = read(STDIN_FILENO, input, sizeof(input));
        if (n == 0) {
            rc = 0;
            break;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read stdin");
            break;
        }

        if (strcmp(format, "pcm") == 0) {
            if (write_all(fifo, input, (size_t)n) < 0) break;
        } else {
            ssize_t i;
            size_t out_samples = 0;
            for (i = 0; i < n; ++i) {
                int16_t sample = linear16_from_ulaw(input[i]);
                pcm[out_samples++] = sample;
                pcm[out_samples++] = sample;
            }
            if (write_all(fifo, pcm, out_samples * sizeof(int16_t)) < 0) break;
        }
    }

    if (stop_requested) rc = 0;

unlock:
    if (speaker_on) switch_speaker(0);
    if (fifo >= 0) close(fifo);
    sem_post(sem);
cleanup:
    if (sem != SEM_FAILED) sem_close(sem);
    return rc;
}

static void print_usage(void) {
    printf("speaker\n\n");
    printf("Usage:\n");
    printf("  speaker on|off\n");
    printf("  speaker stream ulaw|pcm\n\n");
    printf("stream ulaw accepts G.711 mu-law 8 kHz mono on stdin and writes PCM16LE 16 kHz mono to %s.\n", AUDIO_FIFO);
    printf("stream pcm accepts PCM16LE 16 kHz mono on stdin.\n");
}

int main(int argc, char *argv[]) {
    if (argc == 2) {
        if (strcmp(argv[1], "on") == 0) return switch_speaker(1) == 0 ? 0 : 1;
        if (strcmp(argv[1], "off") == 0) return switch_speaker(0) == 0 ? 0 : 1;
    }

    if (argc == 3 && strcmp(argv[1], "stream") == 0) {
        return stream_pcm(argv[2]);
    }

    print_usage();
    return 2;
}
