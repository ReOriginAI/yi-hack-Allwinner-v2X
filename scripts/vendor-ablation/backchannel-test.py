#!/usr/bin/env python3
"""Send three seconds of PCMU silence to the advertised ONVIF backchannel.

Checks negotiation and FIFO consumer presence, not physical speaker acoustics.
"""
import argparse
import re
import socket
import struct
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('host')
a = p.parse_args()
url = 'rtsp://' + a.host + ':554/ch0_0.h264'
s = socket.create_connection((a.host, 554), 5)
s.settimeout(8)
seq = 0
pending = b''


def request(method, target, headers=None):
    global seq, pending
    seq += 1
    hdr = {'CSeq': str(seq), 'Require': 'www.onvif.org/ver20/backchannel'}
    hdr.update(headers or {})
    s.sendall((method + ' ' + target + ' RTSP/1.0\r\n' + ''.join(k + ': ' + v + '\r\n' for k,v in hdr.items()) + '\r\n').encode())
    while b'\r\n\r\n' not in pending:
        block = s.recv(8192)
        if not block: raise EOFError('RTSP EOF')
        pending += block
    head, pending = pending.split(b'\r\n\r\n', 1)
    lines = head.decode().split('\r\n')
    code = int(lines[0].split()[1])
    fields = dict((k.lower(),v.strip()) for k,v in (line.split(':',1) for line in lines[1:]))
    length = int(fields.get('content-length','0'))
    while len(pending) < length:
        block = s.recv(8192)
        if not block: raise EOFError('RTSP body EOF')
        pending += block
    body, pending = pending[:length], pending[length:]
    print(method,code,flush=True)
    if code != 200: raise RuntimeError(lines[0])
    return fields, body.decode()


_, sdp = request('DESCRIBE',url,{'Accept':'application/sdp'})
tracks = [x for x in re.split(r'(?m)^m=', sdp) if 'PCMU/8000' in x and 'a=sendonly' in x]
assert len(tracks) == 1, sdp
control = re.search(r'a=control:([^\r\n]+)',tracks[0]).group(1)
print('Backchannel control:',control,flush=True)
h,_ = request('SETUP',url+'/'+control,{'Transport':'RTP/AVP/TCP;unicast;interleaved=0-1'})
session = h['session'].split(';')[0]
channel = int(re.search(r'interleaved=(\d+)',h['transport']).group(1))
request('PLAY',url,{'Session':session})
for n in range(150):
    packet = struct.pack('!BBHII',0x80,0,n,160*n,0x59694861) + b'\xff'*160
    s.sendall(b'$'+bytes([channel])+struct.pack('!H',len(packet))+packet)
    if n == 30:
        result = subprocess.check_output(['ssh','root@'+a.host,
            "for p in /proc/[0-9]*; do n=$(cat $p/comm 2>/dev/null); if [ \"$n\" = speaker ]; then echo SPEAKER:$p; ls -l $p/fd; fi; done"],text=True)
        print(result,flush=True)
        assert '/tmp/audio_in_fifo' in result, 'No speaker FIFO writer during backchannel'
    time.sleep(.02)
request('TEARDOWN',url,{'Session':session})
s.close()
print('PASS: PCMU negotiation and 150 packets delivered to active FIFO consumer')
