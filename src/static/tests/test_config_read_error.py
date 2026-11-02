#!/usr/bin/env python3
"""Config parsing must finish on a persistent read error, not spin on !feof."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'mqtt-config/mqtt-config'

class ConfigReadTests(unittest.TestCase):
    def test_read_error_and_no_duplicate_last_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            harness = root / 'main.c'
            harness.write_text(r'''
#include "config.h"
static int calls;
static void parsed(const char *key, const char *value) { calls++; }
int main(int argc, char **argv) {
    FILE *fp = fopen(argv[1], "r");
    if (!fp) return 1;
    config_set_handler(parsed);
    config_parse(fp);
    int error = ferror(fp);
    fclose(fp);
    return argc == 2 ? !error : calls != 1;
}
''')
            binary = root / 'test'
            subprocess.run(['cc', '-I', str(SOURCE), str(harness),
                            str(SOURCE / 'config.c'), '-o', str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary), str(root)], timeout=2, check=True)
            config = root / 'config'
            config.write_text('KEY=value\n')
            subprocess.run([str(binary), str(config), 'normal'], timeout=2, check=True)

if __name__ == '__main__':
    unittest.main()
