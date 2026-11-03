#!/bin/sh
# Stock Yi firmware sources this SD hook. No image at the SD root is needed yet.
if [ -f /tmp/sd/Factory/factory_test.sh ] && [ -s /tmp/sd/Factory/config.sh ]; then
    exec /bin/sh /tmp/sd/Factory/config.sh
fi
if [ -f /home/app/lower_half_init.sh ]; then
    exec /bin/sh /home/app/lower_half_init.sh
fi
exec /bin/sh /backup/lower_half_init.sh
