#!/usr/bin/env bash
# Install a saved crontab as the live one, with a pre-flight check first and a
# dated copy of what it replaces. Run ON thanos as the `aiida` user.
#
#   bash restore-crontab.sh                        # uses crontab.txt beside this script
#   bash restore-crontab.sh ~/crontab.suspended-2026-08-24.txt
#
# Written to put the backup crontab back after it was suspended for the 24.04
# upgrade, where it had been off for 16 days and nobody noticed. The preflight
# is what makes that safe to repeat: it checks every project named in the file
# has a venv and that every named profile exists in its config, and it never
# invokes `verdi`, so it cannot migrate a profile's config.
#
# The expected entry count is read from the file being installed rather than
# hardcoded, so this still works after the crontab changes.
set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
SAVED="${1:-$HERE/crontab.txt}"
PREFLIGHT="$HERE/crontab-preflight.sh"

[[ -f "$SAVED"     ]] || { echo "missing: $SAVED" >&2; exit 1; }
[[ -f "$PREFLIGHT" ]] || { echo "missing: $PREFLIGHT" >&2; exit 1; }

# A cron entry starts with a digit or a `*` in the minute field. Comments,
# blank lines and `NAME=value` assignments are not entries.
count_entries() { grep -cE '^[[:space:]]*([0-9*])' "$1" || true; }

expected=$(count_entries "$SAVED")
(( expected > 0 )) || { echo "$SAVED contains no cron entries" >&2; exit 1; }

echo "== current state =="
printf '  active entries now : %s\n' "$(crontab -l 2>/dev/null | grep -cE '^[[:space:]]*([0-9*])' || true)"
printf '  entries in %s : %s\n' "$(basename "$SAVED")" "$expected"

echo
echo "== pre-flight (read-only) =="
bash "$PREFLIGHT" "$SAVED"

echo
read -rp "Install $SAVED as the crontab? [y/N] " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted, nothing changed"; exit 0; }

# Keep a dated copy of what is being replaced, so this is reversible.
BEFORE="$HOME/crontab.before-restore-$(date +%Y%m%d-%H%M%S).txt"
crontab -l > "$BEFORE" 2>/dev/null || true
echo "  replaced crontab saved to $BEFORE"

crontab "$SAVED"

echo
echo "== after =="
n=$(crontab -l | grep -cE '^[[:space:]]*([0-9*])')
printf '  active entries now : %s (expected %s)\n' "$n" "$expected"
if [[ "$n" != "$expected" ]]; then
  echo "  UNEXPECTED COUNT. Inspect with: crontab -l" >&2
  echo "  Revert with: crontab $BEFORE" >&2
  exit 1
fi
echo "  first run at the earliest slot in the file."
