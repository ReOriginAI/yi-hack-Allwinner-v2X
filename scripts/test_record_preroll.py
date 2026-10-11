#!/usr/bin/env python3
"""Exercise the native duration code with stale clocks, wrapped rings and bounds.

Optional --vendor-dir checks actual audited recorder patch output as well.
Requires a host C compiler and BusyBox; built ARM extensions live in _install.
"""
import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ipc_cmd/ipc_cmd"
LIB = ROOT / "src/ipc_cmd/_install/lib"
SCRIPT = ROOT / "src/static/static/yi-hack/script/prepare_mp4record.sh"
PROFILES = {
    "y623": (0xe0000, "06774adfc4368e7dede2ea618a96c2b6"),
    "y28ga": (0x100000, "0d7a4ca9e73fd75806a6ebb75a8accbc"),
}

HARNESS = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned char *storage;
const uint32_t *test_ring;
static unsigned capacity, held, locks, unlocks;
void test_lock(void) { assert(!held); held=1; locks++; }
void test_unlock(void) { assert(held); held=0; unlocks++; }
void test_copy(const void *p,void *out,unsigned n) {
 assert(held && n==28);
 unsigned off=(const unsigned char *)p-storage-368;
 assert(off<capacity);
 for(unsigned i=0;i<n;i++) ((unsigned char *)out)[i]=storage[368+(off+i)%capacity];
}
extern uint32_t record_ring_duration(void);
static void frame(unsigned *p,unsigned bytes,uint32_t pts) {
 uint32_t h[7]={bytes,1,1791690000,0,pts,0x401,0};
 for(unsigned i=0;i<28;i++) storage[368+(*p+i)%capacity]=((unsigned char *)h)[i];
 *p=(*p+bytes+28)%capacity;
}
static uint32_t span(uint32_t a,uint32_t b,unsigned oldest) {
 memset(storage,0,capacity+368);
 uint32_t *base=(uint32_t *)storage;
 base[1]=356;base[4]=oldest;base[5]=2311669270U; /* stale producer time */
 unsigned p=oldest;frame(&p,150,a);frame(&p,150,b);
 return record_ring_duration();
}
int main(int argc,char **argv) {
 assert(argc==2);capacity=strtoul(argv[1],0,0);
 storage=calloc(1,capacity+368);assert(storage);test_ring=(uint32_t *)storage;
 assert(span(690000000,690008500,0)==8500);
 assert(span(690000000,690008500,capacity-10)==8500); /* header and payload wrap */
 assert(span(0xfffff000,0x00001134,capacity-10)==8500); /* timestamp wrap */
 assert(span(10000,10000,0)==0);
 assert(span(20000,10000,0)==0); /* clock discontinuity */
 assert(span(100,200000,0)==0); /* implausible duration */
 memset(storage,0,capacity+368);assert(record_ring_duration()==0);
 ((uint32_t *)storage)[1]=capacity+1;assert(record_ring_duration()==0);
 ((uint32_t *)storage)[1]=28;((uint32_t *)storage)[4]=capacity;assert(record_ring_duration()==0);
 ((uint32_t *)storage)[4]=0;((uint32_t *)(storage+368))[0]=UINT32_MAX;
 assert(record_ring_duration()==0); /* malicious length cannot overflow */
 assert(!held && locks==10 && unlocks==10);
 free(storage);puts("PASS: duration uses media clock; ring/time wrap, invalid input and balanced native locks");
}
'''


def run(args, **kw):
    r = subprocess.run(args, text=True, capture_output=True, **kw)
    if r.returncode:
        raise RuntimeError(f"{args}:\n{r.stdout}\n{r.stderr}")
    return r


def patch_checks(temp, vendor_dir):
    for model, (_, expected) in PROFILES.items():
        prefix = temp / model
        (prefix / "bin").mkdir(parents=True)
        (prefix / "lib").symlink_to(LIB)
        stock = vendor_dir / ("mp4record-" + model)
        env = {**os.environ, "MODEL_SUFFIX": model, "YI_HACK_PREFIX": str(prefix),
               "MP4RECORD_STOCK_PATH": str(stock)}
        path = Path(run(["busybox", "ash", str(SCRIPT)], env=env).stdout.strip())
        data = path.read_bytes()
        assert hashlib.md5(data).hexdigest() == expected
        assert path.stat().st_mode & 0o111
        assert run(["busybox", "ash", str(SCRIPT)], env=env).stdout.strip() == str(path)
        # An unknown vendor must be refused even with a valid cached patch.
        unknown = prefix / "unknown"
        unknown.write_bytes(stock.read_bytes() + b"changed")
        env["MP4RECORD_STOCK_PATH"] = str(unknown)
        r = subprocess.run(["busybox", "ash", str(SCRIPT)], env=env, capture_output=True)
        assert r.returncode != 0 and b"refusing unknown" in r.stderr
        # A known already bound image must stay idempotent.
        env["MP4RECORD_STOCK_PATH"] = str(path)
        assert run(["busybox", "ash", str(SCRIPT)], env=env).stdout.strip() == str(path)
        # Appended helper is fully mapped executable without moving vendor data.
        phoff = struct.unpack_from("<I", data, 28)[0]
        rx = struct.unpack_from("<8I", data, phoff + 2 * 32)
        assert rx[0] == 1 and rx[2] == 0x10000 and rx[4] == len(data) and rx[6] == 5
        print("PASS:", model, "audited binary extension, cache, unknown firmware refusal, idempotency")
        if model == "y28ga":
            # Disabling the subencoder must recognize the image actually bound
            # to the vendor path, while stock/unknown muxers retain their input.
            policy = (ROOT / "src/static/static/yi-hack/script/rtsp_stream_venc.sh").read_text()
            policy = policy[:policy.index('# Runtime low-VENC control')]
            harness = '\nmp4record_running() { return 0; }\nrecording_needs_low_venc && printf needed || printf optional\n'
            legacy = hashlib.md5(stock.read_bytes()).hexdigest() == "c541480baa510ad34944e9e763c6b505"
            for binary, expected_state in ((path, "optional"), (stock, "optional" if legacy else "needed"),
                                           (unknown, "needed")):
                policy_env = {**env, "MP4RECORD_PATH": str(binary)}
                result = run(["busybox", "ash", "-c", policy + harness], env=policy_env)
                assert result.stdout == expected_state
            print("PASS: bound preroll y28ga recorder permits paused subencoder; unknown/stock keep it running")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="yi-preroll-test-") as folder:
        temp = Path(folder)
        harness = temp / "test.c"
        harness.write_text(HARNESS)
        for model, (capacity, _) in PROFILES.items():
            exe = temp / (model + "-test")
            run(["cc", "-Os", "-Wall", "-Wextra", "-Werror", "-DPREROLL_TEST",
                 "-DPREROLL_" + model.upper(), str(SOURCE / "record_preroll.c"),
                 str(harness), "-o", str(exe)])
            print(model, run([str(exe), str(capacity)]).stdout.strip())
        if args.vendor_dir:
            patch_checks(temp, args.vendor_dir)


if __name__ == "__main__":
    main()
