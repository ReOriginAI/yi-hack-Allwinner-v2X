#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s 0..100\n", argv[0]); return 2; }
    int value = atoi(argv[1]);
    if (value < 0 || value > 100) { fprintf(stderr, "value must be 0..100\n"); return 2; }
    int fd = open("/dev/cpld_periph", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    unsigned long cmd = 0x7013; /* CPLD ioctl magic 'p', command 19: IR PWM duty */
    int rc = ioctl(fd, cmd, &value);
    if (rc < 0) fprintf(stderr, "ioctl: %s\n", strerror(errno));
    else printf("IR PWM value=%d rc=%d\n", value, rc);
    close(fd);
    return rc < 0;
}
