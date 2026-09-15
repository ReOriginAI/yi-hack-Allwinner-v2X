/* Run with and without LD_PRELOAD; outputs and statuses must match. */
#include <stdio.h>
#include <assert.h>
int main(void)
{
    const char *commands[] = {
        "cat /sys/block/mmcblk0/device/cid 2>/dev/null",
        "printf local-test",
        "exit 7",
    };
    for (unsigned i = 0; i < 3; i++) {
        FILE *f = popen(commands[i], "r");
        assert(f);
        char buf[128];
        size_t n;
        printf("command %u: ", i);
        while ((n = fread(buf, 1, sizeof(buf), f)) != 0)
            fwrite(buf, 1, n, stdout);
        printf(" status=%d\n", pclose(f));
    }
    return 0;
}
