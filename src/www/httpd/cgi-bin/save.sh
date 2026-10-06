#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/config_work.sh"
if ! config_work_begin; then
    printf "Status: 503 Service Unavailable\r\nContent-type: text/plain\r\n\r\nConfiguration backup is unavailable\n"
    exit 1
fi
cd "$CONFIG_WORK" || exit 1
cp "$YI_HACK_PREFIX"/etc/*.conf . || exit 1
if [ -f "$YI_HACK_PREFIX/etc/hostname" ]; then
    cp "$YI_HACK_PREFIX/etc/hostname" . || exit 1
fi
set -- *.conf
[ ! -f hostname ] || set -- "$@" hostname
(ulimit -f 1024 || exit 1; tar cf config.tar "$@") 2>/dev/null || exit 1
bzip2 config.tar || exit 1
printf "Content-type: application/octet-stream\r\n\r\n"
cat config.tar.bz2
