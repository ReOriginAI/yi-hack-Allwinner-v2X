#!/bin/sh
# Compatibility handoff for ReOriginAI bootstraps released before a fresh SD
# Factory install took precedence in /backup/init.sh. Older bootstraps still run
# yi-hack/startup.sh, so let the complete release install itself once.
if [ -e /tmp/sd/Factory/factory_test.sh ] && \
   [ -s /tmp/sd/Factory/config.sh ] && \
   [ -s /tmp/sd/Factory/local_init.sh ]; then
    echo "yi-hack: completing SD Factory install" > /dev/console
    exec /bin/sh /tmp/sd/Factory/config.sh
fi
exit 0
