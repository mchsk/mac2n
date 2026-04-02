#!/bin/sh
# Wait for network before exec-ing the real binary.
# Used by LaunchDaemon plists to avoid crash-looping at boot.
i=0
while [ "$i" -lt 60 ]; do
    if /sbin/route -n get default >/dev/null 2>&1; then
        exec "$@"
    fi
    sleep 2
    i=$((i + 2))
done
exec "$@"
