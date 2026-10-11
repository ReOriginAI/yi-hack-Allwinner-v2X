#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
printf 'Content-type: application/json\r\nCache-Control: no-store\r\n\r\n'
"$YI_HACK_PREFIX/script/nightvision.sh" status
