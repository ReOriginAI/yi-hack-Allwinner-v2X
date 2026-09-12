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

static uint16_t read_le16(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t read_le32(const unsigned char *p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static int copy_bytes(FILE *input, uint32_t count) {
    unsigned char buf[4096];

    while (count > 0) {
        size_t want = count < sizeof(buf) ? (size_t)count : sizeof(buf);
        size_t n = fread(buf, 1, want, input);
        if (n == 0) {
            if (ferror(input)) perror("read audio file");
            return -1;
        }
        if (fwrite(buf, 1, n, stdout) != n) {
            perror("write stdout");
            return -1;
        }
        count -= (uint32_t)n;
    }

    return 0;
}

static int copy_to_eof(FILE *input) {
    unsigned char buf[4096];
    size_t n;

    while ((n = fread(buf, 1, sizeof(buf), input)) > 0) {
        if (fwrite(buf, 1, n, stdout) != n) {
            perror("write stdout");
            return -1;
        }
    }

    if (ferror(input)) {
        perror("read audio file");
        return -1;
    }
    return 0;
}

/*
 * Decode a stored speaker file to the camera-native format on stdout.
 * Raw files are treated as PCM16LE/16000/mono. RIFF/WAVE files are parsed
 * and accepted only when they contain uncompressed PCM16LE/16000/mono.
 */
static int decode_audio_file(const char *path) {
    unsigned char header[12];
    unsigned char chunk[8];
    unsigned char fmt[16];
    FILE *input;
    int fmt_seen = 0;
    int fmt_valid = 0;
    long data_offset = -1;
    uint32_t data_size = 0;

    input = fopen(path, "rb");
    if (input == NULL) {
        perror("open audio file");
        return 1;
    }

    if (fread(header, 1, sizeof(header), input) != sizeof(header)) {
        if (ferror(input)) perror("read audio file");
        fclose(input);
        fprintf(stderr, "Audio file is too small\n");
        return 1;
    }

    if (memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0) {
        if (fseek(input, 0, SEEK_SET) != 0) {
            perror("seek audio file");
            fclose(input);
            return 1;
        }
        if (copy_to_eof(input) != 0) {
            fclose(input);
            return 1;
        }
        fclose(input);
        return 0;
    }

    while (fread(chunk, 1, sizeof(chunk), input) == sizeof(chunk)) {
        uint32_t chunk_size = read_le32(chunk + 4);
        long payload_offset = ftell(input);
        long skip = (long)chunk_size + (long)(chunk_size & 1U);

        if (payload_offset < 0) {
            perror("tell audio file");
            fclose(input);
            return 1;
        }

        if (memcmp(chunk, "fmt ", 4) == 0) {
            uint16_t format;
            uint16_t channels;
            uint32_t sample_rate;
            uint16_t block_align;
            uint16_t bits_per_sample;

            if (chunk_size < sizeof(fmt) || fread(fmt, 1, sizeof(fmt), input) != sizeof(fmt)) {
                fprintf(stderr, "Invalid WAV fmt chunk\n");
                fclose(input);
                return 1;
            }

            format = read_le16(fmt);
            channels = read_le16(fmt + 2);
            sample_rate = read_le32(fmt + 4);
            block_align = read_le16(fmt + 12);
            bits_per_sample = read_le16(fmt + 14);

            fmt_seen = 1;
            fmt_valid = format == 1 && channels == 1 && sample_rate == 16000 &&
                        bits_per_sample == 16 && block_align == 2;
        } else if (memcmp(chunk, "data", 4) == 0 && data_offset < 0) {
            data_offset = payload_offset;
            data_size = chunk_size;
        }

        if (fseek(input, payload_offset + skip, SEEK_SET) != 0) {
            perror("seek WAV chunk");
            fclose(input);
            return 1;
        }
    }

    if (!fmt_seen || !fmt_valid) {
        fprintf(stderr, "Unsupported WAV format; expected PCM16LE 16 kHz mono\n");
        fclose(input);
        return 1;
    }
    if (data_offset < 0 || data_size == 0) {
        fprintf(stderr, "WAV data chunk not found\n");
        fclose(input);
        return 1;
    }
    if (fseek(input, data_offset, SEEK_SET) != 0) {
        perror("seek WAV data");
        fclose(input);
        return 1;
    }

    if (copy_bytes(input, data_size) != 0) {
        fclose(input);
        return 1;
    }

    fclose(input);
    return 0;
}

static void print_usage(void) {
    printf("speaker\n\n");
    printf("Usage:\n");
    printf("  speaker on|off\n");
    printf("  speaker stream ulaw|pcm\n");
    printf("  speaker decode FILE\n\n");
    printf("stream ulaw accepts G.711 mu-law 8 kHz mono on stdin and writes PCM16LE 16 kHz mono to %s.\n", AUDIO_FIFO);
    printf("stream pcm accepts PCM16LE 16 kHz mono on stdin.\n");
    printf("decode writes camera-native PCM to stdout from raw PCM16LE/16000/mono or compatible PCM WAV.\n");
}

int main(int argc, char *argv[]) {
    if (argc == 2) {
        if (strcmp(argv[1], "on") == 0) return switch_speaker(1) == 0 ? 0 : 1;
        if (strcmp(argv[1], "off") == 0) return switch_speaker(0) == 0 ? 0 : 1;
    }

    if (argc == 3 && strcmp(argv[1], "stream") == 0) {
        return stream_pcm(argv[2]);
    }

    if (argc == 3 && strcmp(argv[1], "decode") == 0) {
        return decode_audio_file(argv[2]);
    }

    print_usage();
    return 2;
}
