#!/bin/bash
#
# Push ~/.config/containers/storage.conf into every existing LMS user's
# home directory. Idempotent: skips users who already have a file (so it
# never overrides a user's own customization). Run once after the
# corresponding /etc/profile.d/podman-storage-conf.sh puppet change has
# landed and run, to cover users who won't log in soon.
#
# Run as root on lms-login (where /mnt/home is locally accessible and the
# script can chown into user homes). Requires the USERS file in this repo
# (regenerate with extract-users.py).
#
# Safe to re-run.

set -euo pipefail

USERS_FILE="$(dirname "$0")/USERS"
HOME_BASE="/mnt/home"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

if [[ ! -f "$USERS_FILE" ]]; then
    echo "ERROR: $USERS_FILE not found — run extract-users.py first" >&2
    exit 1
fi

read -r -d '' STORAGE_CONF <<'EOF' || true
[storage]
driver = "vfs"
rootless_storage_path = "/scratch/containers/$USER/storage"
EOF

deployed=0
skipped=0
missing=0
nouser=0

while IFS= read -r user || [[ -n "$user" ]]; do
    [[ -z "$user" || "$user" =~ ^[[:space:]]*# ]] && continue

    if ! id -u "$user" >/dev/null 2>&1; then
        echo "skip $user: not in passwd database (puppet-only account?)"
        nouser=$((nouser + 1))
        continue
    fi

    home="$HOME_BASE/$user"
    if [[ ! -d "$home" ]]; then
        echo "skip $user: no home directory at $home"
        missing=$((missing + 1))
        continue
    fi

    target="$home/.config/containers/storage.conf"
    if [[ -f "$target" ]]; then
        echo "skip $user: $target already exists"
        skipped=$((skipped + 1))
        continue
    fi

    group="$(id -gn "$user")"

    if ! install -d -o "$user" -g "$group" -m 0700 "$home/.config" \
      || ! install -d -o "$user" -g "$group" -m 0700 "$home/.config/containers"; then
        echo "skip $user: failed to create $home/.config{,/containers}"
        missing=$((missing + 1))
        continue
    fi

    printf '%s\n' "$STORAGE_CONF" > "$target"
    chown "$user:$group" "$target"
    chmod 0644 "$target"

    echo "deployed: $user"
    deployed=$((deployed + 1))
done < "$USERS_FILE"

echo
echo "Summary: $deployed deployed, $skipped already had file, $missing no/unwritable home dir, $nouser not in passwd"
