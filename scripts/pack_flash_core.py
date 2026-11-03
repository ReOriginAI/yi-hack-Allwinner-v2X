#!/usr/bin/env python3
"""Build offline flash-core candidates; never writes an MTD device or camera.
Inputs are extracted, audited vendor trees and a freshly compiled shared payload.
Outputs have non-trigger names intentionally: no automatic SD flashing files.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import tarfile
import struct

ROOT = Path(__file__).resolve().parents[1]
STOCK_RMM = {'y623':'f8164a1c221ba8c1d4888322a3cf0706','y28ga':'46261d809c58dea5b39f3351e322d710'}
OPTIONAL_BIN = {'go2rtc','python3','rsync','rtsp_server_yi','mqttv4','mqtt-config','mqtt-pub','mqtt-sub','proxychains4','nanotts','tts','imggrabber'}
OPTIONAL_LIB = {'libffi.so','libffi.so.8','libffi.so.8.2.0','libwolfmqtt.so.20','libwolfssl.so.45','libproxychains4.so'}
DISABLED = ['cloud','p2p_tnp','oss','oss_fast','oss_lapse','rtmp','recbackup','watch_process','cloudAPI']
LIMITS = {'rootfs':0x120000,'home':0x340000,'backup':0x130000}

def md5(path): return hashlib.md5(path.read_bytes()).hexdigest()
def run(args, **kw): subprocess.run([str(x) for x in args],check=True,**kw)
def jffs2_geometry(image, erase=4096):
    data=image.read_bytes();offset=0;nodes=0;crossing=0
    while offset+12<=len(data):
        magic,kind,length=struct.unpack_from('<HHI',data,offset)
        if magic==0x1985 and 12<=length<=len(data)-offset:
            nodes+=1
            crossing+=int(offset%erase+length>erase)
            offset+=(length+3)&~3
        else:offset+=4
    if not nodes:raise ValueError('no JFFS2 nodes in generated image')
    return {'physical_erase_bytes':erase,'nodes_crossing_blocks':crossing,'flashable':crossing==0}
def copy(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(src,dst)
def deduplicate(directory):
    seen={}
    for p in sorted(directory.rglob('*')):
        if not p.is_file() or p.is_symlink(): continue
        key=(hashlib.sha256(p.read_bytes()).digest(),p.stat().st_mode & 0o777)
        if key in seen:
            target=os.path.relpath(seen[key],p.parent)
            p.unlink();p.symlink_to(target)
        else:seen[key]=p

def check_dependencies(trees):
    """Resolve ELF loaders and DT_NEEDED within the image, with no SD mounted."""
    def host(parts):
        if parts and parts[0] in ('home','backup'):return trees.joinpath(*parts)
        return (trees/'rootfs').joinpath(*parts)
    def resolve(name):
        pending=name.strip('/').split('/');done=[]
        for _ in range(128):
            if not pending: return host(done)
            item=pending.pop(0)
            if item in ('','.'):continue
            if item=='..':
                if done:done.pop()
                continue
            candidate=host(done+[item])
            if candidate.is_symlink():
                target=os.readlink(candidate)
                if target.startswith('/'):done=[]
                pending=target.split('/')+pending
            elif candidate.exists():done.append(item)
            else:return None
        raise ValueError('symlink loop: '+name)
    paths=['/lib','/usr/lib','/home/lib','/home/qigan/lib','/home/app/locallib','/home/yi-hack/lib']
    queue=[p for p in (trees/'home/yi-hack').rglob('*') if not p.is_symlink() and p.is_file()]
    queue += [trees/'home/app'/name for name in ('rmm','dispatch','mp4record')]
    if (trees/'backup/tools/hostapd').exists():queue.append(trees/'backup/tools/hostapd')
    checked=set()
    while queue:
        path=queue.pop()
        if path in checked:continue
        checked.add(path)
        with path.open('rb') as stream:
            if stream.read(4)!=b'\x7fELF':continue
        dyn=subprocess.check_output(['readelf','-d',str(path)],text=True)
        program=subprocess.check_output(['readelf','-l',str(path)],text=True)
        needed=re.findall(r'Shared library: \[(.*?)\]',dyn)
        loader=re.findall(r'Requesting program interpreter: (.*?)\]',program)
        for name in needed+loader:
            candidates=[name] if name.startswith('/') else [posixpath.join(base,name) for base in paths]
            dependency=next((p for name in candidates if (p:=resolve(name)) is not None),None)
            if dependency is None:raise ValueError(f'missing dependency {name} of {path.relative_to(trees)}')
            queue.append(dependency)
    return len(checked)

def build(a):
    model=a.model
    if md5(a.home/'app/rmm') != STOCK_RMM[model]: raise ValueError('unrecognized vendor rmm')
    spec=importlib.util.spec_from_file_location('bootstrap',ROOT/'scripts/vendor-ablation/render.py');renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
    if (a.home/'homever').read_text().strip()!=renderer.FIRMWARE[model]:raise ValueError('unrecognized vendor firmware')
    if md5(a.noop)!='b92bc72d8b7019ec751c36235e92fba5':raise ValueError('unrecognized noop stub')
    if md5(a.payload/'lib/libasound.so.2')!='4f0099fa6f3626e82a1d9e5f738ca5b3':raise ValueError('unrecognized FIFO-safe ALSA')
    if a.output.exists(): raise ValueError('output must not exist; preserve previous candidates')
    a.output.mkdir(mode=0o700,parents=True)
    trees=a.output/'trees';trees.mkdir()
    for name,src in [('rootfs',a.rootfs),('home',a.home),('backup',a.backup)]:
        shutil.copytree(src,trees/name,symlinks=True)
    home=trees/'home';rootfs=trees/'rootfs';backup=trees/'backup';core=home/'yi-hack'
    # Keep an SD mountpoint even before tmpfs setup. This also lets an older
    # pending dispatcher reach its verified SD repair on a recovery boot.
    (rootfs/'tmp/sd').mkdir(parents=True,exist_ok=True)
    # Import build artifacts only, never runtime settings, keys or recordings.
    core.mkdir()
    for name in ['bin','lib','sbin','usr','www/onvif']:
        if (a.payload/name).exists():shutil.copytree(a.payload/name,core/name,symlinks=True)
    shutil.copytree(ROOT/'src/static/static/yi-hack',core,dirs_exist_ok=True,symlinks=True)
    shutil.copytree(a.web,core/'www',dirs_exist_ok=True,symlinks=True)
    (core/'www/record').mkdir(exist_ok=True)
    (core/'flash-core').write_text('1\n')
    (core/'model_suffix').write_text(model+'\n')
    (core/'version').write_text((ROOT/'VERSION').read_text().strip()+'-flash-core\n')
    (core/'etc/hostname').write_text('yi-hack-'+model+'\n')
    conf=core/'etc/system.conf'
    conf.write_text(conf.read_text().replace('BUSYBOX_FTPD=no','BUSYBOX_FTPD=yes').replace('SWAP_FILE=yes','SWAP_FILE=no'))
    with tarfile.open(core/'etc/defaults.tar.bz2','w:bz2') as archive:
        for path in sorted((core/'etc').glob('*.conf')):archive.add(path,arcname=path.name)
    # Validate and install the existing audited native patches into the image.
    env=dict(os.environ,YI_HACK_PREFIX=str(core),MODEL_SUFFIX=model)
    for script,stock,target in [('prepare_rmm.sh','rmm','rmm'),('prepare_mp4record.sh','mp4record','mp4record')]:
        patched=a.output/(stock+'.patched')
        names={'RMM_STOCK_PATH':str(home/'app/rmm'),'RMM_PATCHED_PATH':str(patched)} if stock=='rmm' else {'MP4RECORD_STOCK_PATH':str(home/'app/mp4record'),'MP4RECORD_PATCHED_PATH':str(patched)}
        run([a.host_busybox,'ash',core/'script'/script],env=dict(env,**names),stdout=subprocess.DEVNULL)
        copy(patched,home/'app'/target);patched.unlink()
    # Keep the shared speaker FIFO fix while storing only one ALSA implementation.
    if md5(rootfs/'lib/libasound.so.2') != '0a980a4b0262533d2f21eca2b2dd8ad1': raise ValueError('unknown vendor ALSA')
    copy(core/'lib/libasound.so.2',rootfs/'lib/libasound.so.2.0.0')
    for p in (core/'lib').glob('libasound*'):p.unlink()
    optional=a.output/'sd-optional/yi-hack-optional'
    (optional/'lib').mkdir(parents=True)
    for path in ['usr/share/pico', 'usr/lib/python3']:
        p=core/path
        if p.exists():
            destination=optional/path;destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.move(p,destination)
        p.parent.mkdir(parents=True,exist_ok=True)
        p.symlink_to('/tmp/sd/yi-hack-optional/'+path)
    for p in list((core/'bin').iterdir()):
        if p.name in OPTIONAL_BIN:
            copy(p,optional/'bin'/p.name);p.unlink();p.symlink_to('/tmp/sd/yi-hack-optional/bin/'+p.name)
        elif p.name.startswith(('rmm-','mp4record-','h264grabber_')):p.unlink()
    if not (core/'bin/imggrabber-grid').is_file():
        raise ValueError('missing compact motion-grid snapshot binary; rebuild the shared snapshot module')
    # Keep only low-resolution H.264 snapshots in internal flash. Full decoder
    # and watermark resources remain available as optional SD functionality.
    (core/'bin/imggrabber').unlink()
    copy(ROOT/'scripts/flash-core/grid_snapshot.sh',core/'bin/imggrabber')
    (core/'bin/imggrabber').chmod(0o755)
    if (a.payload/'etc/wm_res').is_dir():
        shutil.copytree(a.payload/'etc/wm_res',optional/'etc/wm_res',symlinks=True)
    for p in list((core/'lib').iterdir()):
        if p.name in OPTIONAL_LIB:
            # Resolve every build-time alias before moving its real target.
            copy(p,optional/'lib'/p.name)
    for p in list((core/'lib').iterdir()):
        if p.name in OPTIONAL_LIB:
            p.unlink();p.symlink_to('/tmp/sd/yi-hack-optional/lib/'+p.name)
    for name in ['pure-ftpd']:
        p=core/'sbin'/name
        if p.exists():p.unlink()
    for name in DISABLED:
        p=home/'app'/name
        if p.exists():copy(a.noop,p)
    for path in ['base/tools/7za','model/BodyVehicleAnimal3.model']:
        p=home/path
        if p.exists():p.unlink()
    # Executable updates for the old SD layout must never replace a flash core.
    for name in ['fw_upload.sh','fw_upgrade.sh','fw_online.sh']:
        p=core/'www/cgi-bin'/name
        p.write_text('#!/bin/sh\nprintf "Content-type: application/json\\r\\n\\r\\n"\nprintf \'{"error":true,"message":"Use matching flash-core images; SD payload upgrades are disabled."}\\n\'\n')
        p.chmod(0o755)
    # A small persistent fallback exists even if the data card cannot mount.
    shutil.copytree(core/'etc',backup/'yi-hack-config',dirs_exist_ok=True)
    # Default images/fonts/archive are immutable, and already stored in home.
    # Keep mutable settings/keys in JFFS2 without duplicating those assets.
    for name in ['fallback.jpg','defaults.tar.bz2','watermark']:
        p=backup/'yi-hack-config'/name
        if p.is_dir():shutil.rmtree(p)
        elif p.exists():p.unlink()
        p.symlink_to('/home/yi-hack/etc/'+name)
    copy(backup/'tools/default.script',core/'script/vendor-default.script')
    (backup/'tools/default.script').unlink()
    (backup/'tools/default.script').symlink_to('/home/yi-hack/script/vendor-default.script')
    (backup/'init.sh').write_text(renderer.render(model,a.noop.read_bytes(),core,flash=True));(backup/'init.sh').chmod(0o755)
    # The AP daemon replaces the vendor's station-only build for hotspot duty.
    # Store it in backup; retain a manifest-checked link at the common prefix.
    if model == 'y623':
        copy(core/'bin/hostapd',backup/'tools/hostapd')
        (core/'bin/hostapd').unlink()
        (core/'bin/hostapd').symlink_to('/backup/tools/hostapd')
    # The SD installer already reclaims these obsolete vendor update helpers.
    # Flash profiles disable SD payload upgrades and keep raw recovery inputs.
    for name in ['upgrade.sh','extpkg.sh','rsa_pub_dec','upgrade_firmware','mem_update_pack.sh','update_homefs.sh']:
        (backup/'tools'/name).unlink(missing_ok=True)
    deduplicate(core/'lib');deduplicate(optional/'lib')
    dependencies=check_dependencies(trees)
    report={'model':model,'profile':'flash-core','limits':LIMITS,'images':{},'optional_programs':sorted(OPTIONAL_BIN),'dependency_files_checked':dependencies,'deployed':False}
    for part in ['rootfs','home']:
        image=a.output/(part+'.squashfs')
        run(['mksquashfs',trees/part,image,'-noappend','-comp','xz','-b','262144','-all-root','-no-xattrs','-processors','2'],stdout=(a.output/(part+'.log')).open('w'))
        size=image.stat().st_size
        if size>LIMITS[part]-64: raise ValueError(f'{part} exceeds flash budget: {size}')
        report['images'][part]={'bytes':size,'headroom':LIMITS[part]-size,'sha256':hashlib.sha256(image.read_bytes()).hexdigest()}
    image=a.output/'backup.jffs2'
    run([a.mkfs_jffs2,'-l','-e','4096','-U','-m','size','-x','lzo','-x','rtime','-r',backup,'-o',image])
    size=image.stat().st_size
    if size>LIMITS['backup']-131072:raise ValueError('backup lacks 128 KiB config/recovery headroom')
    report['images']['backup']={'bytes':size,'headroom':LIMITS['backup']-size,'sha256':hashlib.sha256(image.read_bytes()).hexdigest()}
    report['images']['backup'].update(jffs2_geometry(image))
    (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('model',choices=STOCK_RMM)
    for name in ['rootfs','home','backup','payload','web','noop','host-busybox','mkfs-jffs2','output']:p.add_argument('--'+name,type=Path,required=True)
    build(p.parse_args())
