#!/usr/bin/env python3
"""One-shot SSH-controlled no-SD boot simulation. Requires a working local boot.

The SD stays physically inserted. The test boot stops before mounting it,
records state internally, consumes its marker and reboots into local boot.
Never restores a vendor init. Restore the normal local init after retrieving logs.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('host')
p.add_argument('normal_init', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
normal = a.normal_init.read_bytes()


def remote(cmd, data=None):
    return subprocess.run(['ssh','-o','BatchMode=yes',a.host,cmd],input=data,
                          stdout=subprocess.PIPE,check=True).stdout


assert remote('md5sum /backup/init.sh').decode().split()[0] == hashlib.md5(normal).hexdigest()
old = '''fail_closed() {
    echo "yi-hack: fail closed: $*" > /dev/console
    exit 1
}'''
new = '''fail_closed() {
    echo "yi-hack: fail closed: $*" > /dev/console
    if [ -e /backup/local-only-no-sd ]; then
        {
            echo "TEST: SSH-controlled no-SD simulation (card physically present)"
            echo "FAILURE: $*"
            cat /proc/uptime
            ps
            cat /proc/mounts
            netstat -anp
            md5sum /home/app/cloud /home/app/p2p_tnp /home/app/oss /home/app/watch_process /home/app/cloudAPI
        } > /backup/local-only-test.log 2>&1
        rm -f /backup/local-only-no-sd
        sync
        sleep 3
        reboot
    fi
    exit 1
}'''
assert normal.decode().count(old) == 1
fixture = normal.decode().replace(old,new).encode()
a.output.write_bytes(fixture)
remote('cat > /backup/init.sh.local-test',fixture)
md5 = hashlib.md5(fixture).hexdigest()
remote('test "$(md5sum /backup/init.sh.local-test | cut -d \' \' -f1)" = '+md5+
       ' && /bin/sh -n /backup/init.sh.local-test && chmod 755 /backup/init.sh.local-test && sync && mv /backup/init.sh.local-test /backup/init.sh && sync')
remote('touch /backup/local-only-no-sd && sync && reboot')
print('One-shot diagnostic installed; wait for the second boot, retrieve /backup/local-only-test.log, then restore the saved normal LOCAL init.')
