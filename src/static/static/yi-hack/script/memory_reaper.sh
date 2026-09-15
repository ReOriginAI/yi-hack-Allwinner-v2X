#!/bin/sh

# Compatibility entry point retained for older startup hooks/upgrades.
# Memory pressure is handled by the kernel OOM killer; oom_policy.sh only
# protects irreplaceable processes and ranks restartable services as victims.
exec /tmp/sd/yi-hack/script/oom_policy.sh "$@"
