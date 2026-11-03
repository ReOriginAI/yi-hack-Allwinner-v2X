#!/usr/bin/env python3
"""Duplicate SD mounts must not hide the flash core; no real mount calls."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'ipc_cmd/ipc_cmd/flash_mount.c'


class FlashMountTests(unittest.TestCase):
    def test_only_duplicate_flash_sd_mount_is_filtered(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mounts = root / 'mounts'
            mounts.write_text('/dev/mmcblk0p1 /tmp/sd vfat rw 0 0\n')
            code = r'''
#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <assert.h>
static int calls;
static long fake_syscall(long n, ...) { (void)n; calls++; errno=EPERM; return -1; }
#define syscall fake_syscall
#include "SOURCE"
int main(void) {
    setenv("YI_FLASH_CORE","1",1);
    errno=EINTR;
    assert(mount("/dev/mmcblk0p1","/tmp/sd","vfat",0,0)==0);
    assert(errno==EINTR && calls==0);
    assert(mount("/dev/mmcblk0p1","/tmp/sd","vfat",MS_REMOUNT,0)==-1);
    assert(mount("/dev/mmcblk0p1","/tmp/other","vfat",0,0)==-1);
    assert(mount("/dev/mtdblock3","/tmp/sd","squashfs",0,0)==-1);
    unsetenv("YI_FLASH_CORE");
    assert(mount("/dev/mmcblk0p1","/tmp/sd","vfat",0,0)==-1);
    assert(calls==4);
    setenv("YI_FLASH_CORE","1",1);
    FILE *file=fopen(YI_FLASH_MOUNTS_FILE,"w");
    fputs("/dev/mtdblock3 /tmp/sd/yi-hack squashfs ro 0 0\n",file);fclose(file);
    assert(mount("/dev/mmcblk0p1","/tmp/sd","vfat",0,0)==-1);
    assert(calls==5 && errno==EPERM);
    return 0;
}
'''.replace('"SOURCE"', '"' + str(SOURCE) + '"')
            (root / 'test.c').write_text(code)
            subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror',
                            f'-DYI_FLASH_MOUNTS_FILE="{mounts}"', str(root / 'test.c'),
                            '-o', str(root / 'test')], check=True)
            subprocess.run([str(root / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()
