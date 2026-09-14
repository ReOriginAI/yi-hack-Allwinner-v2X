#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s 21|22\n", argv[0]); return 2; }
    int n = atoi(argv[1]);
    if (n != 21 && n != 22) { fprintf(stderr, "command must be 21 or 22\n"); return 2; }
    int fd = open("/dev/cpld_periph", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    unsigned long cmd = 0x7000u | (unsigned)n;
    int rc = ioctl(fd, cmd, 0);
    if (rc < 0) fprintf(stderr, "ioctl: %s\n", strerror(errno));
    else printf("IR-cut command=%d rc=%d\n", n, rc);
    close(fd);
    return rc < 0;
}
