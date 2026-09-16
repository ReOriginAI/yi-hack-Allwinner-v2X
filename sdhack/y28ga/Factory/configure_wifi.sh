#!/bin/sh

# Factory provisioning is data-only. Use the same yi-hack Wi-Fi writer that is
# hash-bound into the hardened bootstrap instead of maintaining a second parser.
CFG_FILE=/tmp/sd/Factory/configure_wifi.cfg
export CFG_FILE
exec /bin/sh /tmp/sd/yi-hack/script/configure_wifi.sh "$@"
