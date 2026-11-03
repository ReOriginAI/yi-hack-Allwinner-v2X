#!/usr/bin/env python3
"""Exercise native reset filtering against synthetic, signature-gated ELFs."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'src/ipc_cmd/ipc_cmd'
PROFILES = {'y623': (0x19b54, [0xe307100e, 0xe5960020, 0xebffdd24]),
            'y28ga': (0x1864c, [0xe307100e, 0xe5960024, 0xebffe267])}
HARNESS = r'''
#define readlink mock_readlink
#include "reset_hotspot.c"
#undef readlink
#include <assert.h>
ssize_t mock_readlink(const char *path, char *target, size_t size) {
    const char *value = strcmp(path, "/proc/self/fd/42") == 0 ? "/dev/cpld_periph" : "/dev/other";
    assert(strlen(value) < size);
    memcpy(target, value, strlen(value));
    return strlen(value);
}
int main(int argc, char **argv) {
    (void)argv;
    if (argc == 2) {
        assert(!profile);
        assert(filter_level(42, 0x700e, 0x19b54, 0, 10000) == 0);
        assert(access(RESET_REQUEST, F_OK) != 0);
        return 0;
    }
    assert(profile);
    assert(access(RESET_ARMED, F_OK) != 0);
    uintptr_t caller = profile->caller;
    /* Only the physical poll, from the audited caller and device, is changed. */
    assert(filter_level(42, 0x700e, caller + 4, 0, 0) == 0);
    assert(filter_level(43, 0x700e, caller, 0, 0) == 0);
    assert(filter_level(42, 0x701c, caller, 0, 0) == 0);
    assert(filter_level(42, 0x700e, caller, -1, 0) == -1);
    assert(access(RESET_ARMED, F_OK) != 0);
    /* Boot-time low samples must not request a hotspot. Release after the
     * startup guard is required before a deliberate five-second hold. */
    assert(filter_level(42, 0x700e, caller, 0, 1000) == 0);
    assert(filter_level(42, 0x700e, caller, 0, 10000) == 0);
    assert(access(RESET_REQUEST, F_OK) != 0);
    assert(filter_level(42, 0x700e, caller, 0, 31000) == 1);
    assert(access(RESET_REQUEST, F_OK) != 0);
    assert(filter_level(42, 0x700e, caller, 1, 35000) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 41000) == 1);
    assert(filter_level(42, 0x700e, caller, -1, 46000) == -1);
    assert(filter_level(42, 0x700e, caller, 0, 46001) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 47000) == 1);
    assert(access(RESET_REQUEST, F_OK) != 0); /* unknown readings break the hold */
    assert(filter_level(42, 0x700e, caller, 1, 48000) == 1);
    assert(filter_level(42, 0x700e, caller, 0, UINT64_MAX) == 1);
    assert(access(RESET_REQUEST, F_OK) != 0); /* failed clock never resets */
    assert(filter_level(42, 0x700e, caller, 0, 50000) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 54999) == 1);
    assert(access(RESET_REQUEST, F_OK) != 0);
    assert(filter_level(42, 0x700e, caller, 0, 55000) == 1);
    FILE *f = fopen(RESET_REQUEST, "r");
    assert(f);
    char message[32];
    assert(fgets(message, sizeof(message), f));
    assert(strcmp(message, "start-open\n") == 0);
    fclose(f);
    unlink(RESET_REQUEST);
    assert(filter_level(42, 0x700e, caller, 0, UINT64_MAX) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 60000) == 1);
    assert(access(RESET_REQUEST, F_OK) != 0); /* one event per hold */
    assert(filter_level(42, 0x700e, caller, 1, 60001) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 61000) == 1);
    assert(filter_level(42, 0x700e, caller, 0, 66000) == 1);
    assert(access(RESET_REQUEST, F_OK) == 0);
    unlink(RESET_REQUEST);
    /* Real unrelated ioctl failures preserve libc's errno contract. */
    int fd = open("/dev/null", O_RDONLY);
    errno = 0;
    assert(ioctl(fd, 0x1234, NULL) == -1 && errno == ENOTTY);
    close(fd);
    return 0;
}
'''

class ResetHotspotTests(unittest.TestCase):
    def test_both_profiles_long_press_and_unrelated_commands(self):
        for model, (caller, words) in PROFILES.items():
            with self.subTest(model=model), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                fake = root / 'dispatch'
                data = bytearray(caller - 0x10000)
                data[-12:] = struct.pack('<III', *words)
                fake.write_bytes(data)
                harness = root / 'test.c'
                harness.write_text(HARNESS)
                binary = root / 'test'
                request = root / 'request'
                subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                                '-I', str(SOURCE), '-D_GNU_SOURCE',
                                f'-DRESET_EXECUTABLE="{fake}"', f'-DRESET_REQUEST="{request}"',
                                f'-DRESET_ARMED="{root / "armed"}"',
                                str(harness), '-pthread', '-ldl', '-o', str(binary)], check=True)
                env = dict(os.environ, YI_RESET_HOTSPOT_MODEL=model)
                subprocess.run([str(binary)], env=env, check=True, timeout=3)
                subprocess.run([str(binary), 'disabled'], env=dict(env, YI_RESET_HOTSPOT_MODEL='unknown'), check=True)
                data[-4:] = b'\0' * 4
                fake.write_bytes(data)
                subprocess.run([str(binary), 'wrong-signature'], env=env, check=True)

if __name__ == '__main__':
    unittest.main()
