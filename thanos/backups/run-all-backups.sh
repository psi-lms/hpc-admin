#!/usr/bin/env bash
# One-shot: run every AiiDA backup on thanos sequentially, now.
#
# Same invocations as crontab-new.txt (19 projects, 36 profiles), run one after
# another instead of on a schedule. Sequential on purpose: 19 concurrent
# pg_dumps plus NFS writes is exactly what the staggered crontab exists to avoid.
#
#   tmux new -s backup
#   bash ~/scripts/hpc-admin/thanos/backups/run-all-backups.sh
#
# Takes hours. The 13 already-covered profiles are incremental against last
# night (--link-dest, fast); the other 23 profiles are first-time full copies of
# roughly 1.55 TB plus their database dumps.
#
# KEEP=N is how many generations verdi retains for the profiles it touches.
#
# NOTE ON RETENTION: raising KEEP here does NOT protect this run's snapshot.
# The crontab passes no -k, so the nightly run falls back to `${keep-3}` and
# prunes to 3 generations. To keep this snapshot through the upgrade, either
# suspend the backup cron for the window, or run the pin-snapshots step printed
# at the end of this script.
set -uo pipefail
export LC_ALL=C

REPO="${REPO:-$HOME/scripts/aiida-backup-script}"
KEEP="${KEEP:-6}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${OUT:-$HOME/backup-run-$STAMP}"
mkdir -p "$OUT"

# project|profiles  -- kept in the same order as crontab-new.txt (largest first)
JOBS=(
  "mc3d-electronic|dev test_2"
  "mc3d-source|prod dev test batio source-test"
  "fermisurf|main"
  "mc3d-relax-so|presto"
  "sssp-project|presto full-24-07"
  "mc3d-super|prod"
  "mc3d-relax-mpds|prod"
  "mc3d-spin_orbit|presto prod"
  "sssp-tests|correct_cutoffs presto precision_tests final_sssp_tests pbesol_tests"
  "mc3d-relax|prod dev"
  "sssp_tutorial|presto"
  "electrides_test|presto"
  "kristjan_tests|mc3d-pbesol-v2 presto"
  "hubml|hubml-dev hubml-prod"
  "ali-playground|dev"
  "thor-dev|thor-dev"
  "pseudo-opt|dev prod"
  "alps_run|arch_final arch_t1 presto-8"
  "mc3d-pbesol-v1|prod"
)

echo "output dir : $OUT"
echo "keep       : $KEEP"
echo "jobs       : ${#JOBS[@]}"
echo "started    : $(date -Is)"
echo

declare -a RESULTS=()
for job in "${JOBS[@]}"; do
  project="${job%%|*}"
  profiles="${job#*|}"
  log="$OUT/$project.log"
  t0=$SECONDS

  printf '%s  %-18s %s\n' "$(date +%H:%M:%S)" "$project" "[$profiles]"
  printf '   watch: tail -f %s\n' "$log"
  "$REPO/aiida-backup.sh" -e aiida-project -n "$project" -p "$profiles" -k "$KEEP" \
      > "$log" 2>&1
  rc=$?
  dt=$(( SECONDS - t0 ))

  # The script exits 0 even when verdi fails, so trust the log, not just $rc.
  ok=$(grep -c '^Success' "$log")
  bad=$(grep -cE '^(Critical|Error|Failure)|Traceback' "$log")
  want=$(wc -w <<<"$profiles")

  if (( rc == 0 && bad == 0 && ok == want )); then
    status="OK"
  else
    status="CHECK rc=$rc success=$ok/$want errors=$bad"
  fi
  RESULTS+=("$(printf '%-18s %-8s %5ds  %s' "$project" "$status" "$dt" "$log")")
  printf '   -> %s (%ds)\n\n' "$status" "$dt"
done

echo "=============================================================="
echo "finished   : $(date -Is)"
echo
printf '%s\n' "${RESULTS[@]}"
echo
echo "Anything not OK: read its log in $OUT"
echo
echo "Snapshot directories this run produced (record these before the upgrade):"
shopt -s nullglob
for d in /nfs/nfsbackup/aiida_thanos/*/*/last-backup; do
  printf '  %-58s -> %s\n' "${d#/nfs/nfsbackup/aiida_thanos/}" "$(readlink "$d")"
done | tee "$OUT/last-backup-targets.txt"

cat <<'NOTE'

--------------------------------------------------------------------------
RETENTION WARNING

The nightly cron passes no -k, so it prunes to 3 generations. This run's
snapshot will be deleted after roughly three more nightly runs, regardless
of the KEEP value used here.

Before the OS upgrade, do ONE of:

  1. Suspend the backup cron for the upgrade window (recommended; you do not
     want a backup firing against a half-migrated PostgreSQL either):

       crontab -l > ~/crontab.suspended-$(date +%F).txt
       crontab -l | sed -E 's|^([[:space:]]*)([0-9])|\1#\2|' | crontab -
       crontab -l | grep -c '^[[:space:]]*[0-9]'   # expect 0

     Restore after the upgrade with:
       crontab ~/crontab.suspended-<date>.txt

  2. Pin this run's snapshots with hard links, so pruning cannot see them
     (costs no space, and leaves last-backup untouched):

       for d in /nfs/nfsbackup/aiida_thanos/*/*/last-backup; do
         t=$(readlink "$d"); p=$(dirname "$d")
         cp -al "$p/$t" "$p/pre-upgrade-$(date +%F)" 2>/dev/null \
           && echo "pinned $p/pre-upgrade-$(date +%F)"
       done

Doing both is cheapest and safest.
--------------------------------------------------------------------------
NOTE
