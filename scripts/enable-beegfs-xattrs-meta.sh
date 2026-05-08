#!/bin/bash
# Enable extended-attribute storage on BeeGFS metadata servers (thor1, thor2).
# Run as root on each metadata server. Idempotent: re-runs are no-ops once the
# value is already 'true'.
#
# Prerequisite for moving rootless-podman storage onto /scratch with the
# overlay driver, which uses xattrs to track layer metadata.

set -eu

CONF=/etc/beegfs/beegfs-meta.conf
KEY=storeClientXAttrs

if ! [ -f "$CONF" ]; then
    echo "no $CONF on $(hostname); is this a BeeGFS metadata server?" >&2
    exit 1
fi

current=$(awk -v k="$KEY" '$1 == k { print $3 }' "$CONF")
echo "before: $KEY = $current"

if [ "$current" = "true" ]; then
    echo "already enabled, nothing to do"
    exit 0
fi

# Backup, then flip the value (or append if missing).
cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
if grep -qE "^$KEY[[:space:]]*=" "$CONF"; then
    sed -i -E "s/^($KEY[[:space:]]*=[[:space:]]*).+$/\1true/" "$CONF"
else
    printf '\n%s = true\n' "$KEY" >> "$CONF"
fi

new=$(awk -v k="$KEY" '$1 == k { print $3 }' "$CONF")
echo "after:  $KEY = $new"

echo "restarting beegfs-meta..."
systemctl restart beegfs-meta
sleep 2
systemctl --no-pager status beegfs-meta | head -5
