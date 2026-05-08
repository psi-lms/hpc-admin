#!/bin/bash
# fix-user-group.sh — set the correct primary group ownership on a user's
# home and scratch trees, plus the setgid bit so future files inherit it.
#
# Solves the `unx-nogroup` problem: PSI's central LDAP returns a fallback
# primary GID that doesn't match either of our local groups (lms, msd), so
# files created by a user default to `unx-nogroup` ownership. We can't fix
# the user's primary group without LDAP / SSSD-override work, but we *can*
# chown all their existing files to the right group, and set the setgid
# bit on their home + scratch dirs so any newly-created file inherits the
# parent's group regardless of the user's primary group.
#
# The right group is derived from the user's Slurm account:
#   account 'prio'   -> group 'msd'   (MSD users, higher priority QoS)
#   account 'normal' -> group 'lms'   (LMS users, regular QoS)
#
# Run as root. Single-user invocation, so it's safe to test on yourself
# first before bulk-applying to everyone.
#
# Usage:
#   fix-user-group.sh [-n|--dry-run] <username>
#
# Examples:
#   sudo ./fix-user-group.sh --dry-run geiger_j     # show what would happen
#   sudo ./fix-user-group.sh geiger_j               # actually do it
#
# Reversal (if you regret it):
#   chown -R <user>:unx-nogroup /mnt/home/<user> /scratch/<user>
#   chmod g-s /mnt/home/<user> /scratch/<user>

set -eu

dry_run=0
if [ "${1:-}" = "-n" ] || [ "${1:-}" = "--dry-run" ]; then
    dry_run=1
    shift
fi

if [ "$#" -ne 1 ]; then
    echo "usage: $0 [-n|--dry-run] <username>" >&2
    exit 2
fi

user=$1

# Confirm the user resolves.
if ! id -u "$user" >/dev/null 2>&1; then
    echo "$user: not a recognised user (id -u failed)" >&2
    exit 1
fi
uid=$(id -u "$user")
current_primary=$(id -gn "$user")

# Look up the Slurm account.
account=$(sacctmgr show user "$user" format=Account -P -n 2>/dev/null | head -1 || true)
if [ -z "$account" ]; then
    echo "$user: no Slurm account found via sacctmgr (is the user in slurm acct DB?)" >&2
    exit 1
fi

# Map slurm account -> UNIX group.
case "$account" in
    prio)   group=msd ;;
    normal) group=lms ;;
    *) echo "$user: unknown slurm account '$account', no UNIX group mapping" >&2
       exit 1 ;;
esac

# Confirm the target group exists in NSS.
if ! getent group "$group" >/dev/null; then
    echo "$user: target group '$group' not found via getent group" >&2
    exit 1
fi

echo "user=$user uid=$uid current_primary_group=$current_primary"
echo "  slurm_account=$account -> target_unix_group=$group"
[ "$dry_run" -eq 1 ] && echo "  (DRY RUN — no changes will be made)"

run() {
    if [ "$dry_run" -eq 1 ]; then
        echo "  [dry-run] $*"
    else
        echo "  + $*"
        "$@"
    fi
}

for dir in "/mnt/home/$user" "/scratch/$user"; do
    if [ -d "$dir" ]; then
        run chown -R "$user:$group" "$dir"
        run chmod g+s "$dir"
    else
        echo "  $dir: no such directory, skipping"
    fi
done

if [ "$dry_run" -eq 0 ]; then
    echo
    echo "done. verify with:"
    echo "  ls -ld /mnt/home/$user /scratch/$user"
    echo "  ls -l /mnt/home/$user/ | head"
    echo
    echo "the user's primary group as reported by 'id' is unchanged"
    echo "(still $current_primary). the setgid bit on the parent dirs is what"
    echo "ensures new files inherit '$group' from now on."
fi
