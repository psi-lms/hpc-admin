#!/usr/bin/env bash
# Everything to do before starting the OS upgrade, in order, as one command.
#
#   ssh -t thanos
#   sudo -v && bash ~/scripts/hpc-admin/thanos/os-upgrade/monday-prep.sh 2>&1 | tee ~/monday-prep-$(date +%F-%H%M).txt
#
# Sudo must be primed on this TTY first: Ubuntu caches the timestamp per-TTY,
# so a bare `sudo` inside a script that was started without one will fail.
#
# The backup crontab is deliberately NOT suspended. It next fires at 00:00, by
# which point the upgrade should be finished. If the upgrade is still running
# at midnight, suspend it then:
#   crontab -l > ~/crontab.suspended-$(date +%F).txt
#   crontab -l | sed -E 's|^([[:space:]]*)([0-9])|\1#\2|' | crontab -
#
# Phases can be skipped individually for a re-run, e.g.
#   SKIP_DUMPALL=1 bash monday-prep.sh
set -uo pipefail
export LC_ALL=C

HERE="$(dirname "$(readlink -f "$0")")"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HOME/monday-prep-$STAMP"
mkdir -p "$OUT"

SKIP_STATE="${SKIP_STATE:-0}"
SKIP_DAEMONS="${SKIP_DAEMONS:-0}"
SKIP_DATADIR="${SKIP_DATADIR:-0}"
SKIP_COLLECT="${SKIP_COLLECT:-0}"
SKIP_RESTORE="${SKIP_RESTORE:-0}"
SKIP_DUMPALL="${SKIP_DUMPALL:-0}"

declare -a SUMMARY=()
phase() { printf '\n\n========== %s ==========\n\n' "$*"; }
note()  { SUMMARY+=("$*"); }

sudo -n true 2>/dev/null || { echo "sudo timestamp not primed. Run: sudo -v"; exit 1; }

echo "output dir : $OUT"
echo "started    : $(date -Is)"
echo "crontab    : left running on purpose, next fires 00:00"

# ---------------------------------------------------------------- 1. state
if (( ! SKIP_STATE )); then
phase "1/6  state left by the weekend"

n=$(ls -d /nfs/nfsbackup/aiida_thanos/*/*/last-backup 2>/dev/null | wc -l)
echo "profiles with a last-backup symlink: $n  (expect 36)"
note "profiles backed up: $n/36"
for f in /nfs/nfsbackup/aiida_thanos/*/*/last-backup; do
  printf '  %-56s -> %s\n' "${f#/nfs/nfsbackup/aiida_thanos/}" "$(readlink "$f")"
done | tee "$OUT/last-backup-targets.txt"

echo
echo "-- profiles whose newest backup is NOT from the last 3 days:"
find /nfs/nfsbackup/aiida_thanos -maxdepth 3 -name last-backup -mtime +3 -printf '  %p\n' || echo "  none"

echo
echo "-- stale pack locks (any hit here needs clearing before the upgrade):"
find /nfs/aiida_data/repositories /home/aiida/project -path '*/packs/*.lock' 2>/dev/null | tee "$OUT/stale-locks.txt"
[[ -s "$OUT/stale-locks.txt" ]] && note "STALE LOCKS FOUND, see $OUT/stale-locks.txt" || { echo "  none"; note "no stale pack locks"; }

echo
echo "-- leftover live-backup staging directories:"
find /nfs/nfsbackup/aiida_thanos -maxdepth 3 -name 'live-backup' 2>/dev/null | tee "$OUT/live-backup-dirs.txt"
[[ -s "$OUT/live-backup-dirs.txt" ]] && note "LEFTOVER live-backup DIRS, see $OUT/live-backup-dirs.txt" || { echo "  none"; note "no leftover live-backup dirs" ; }

echo
echo "-- disk"
df -hT / /home /nfs/nfsbackup /nfs/aiida_data 2>/dev/null | tee "$OUT/disk.txt"
note "nfsbackup free: $(df -h /nfs/nfsbackup | awk 'NR==2{print $4}')"
fi

# -------------------------------------------------------------- 2. daemons
if (( ! SKIP_DAEMONS )); then
phase "2/6  stopping AiiDA daemons"
for v in "$HOME"/.aiida_venvs/*/bin/verdi; do
  [[ -x "$v" ]] || continue
  proj=$(basename "$(dirname "$(dirname "$v")")")
  printf '  %-22s ' "$proj"
  "$v" daemon stop --all >>"$OUT/daemon-stop.log" 2>&1 && echo "stopped" || echo "nothing running / error (see daemon-stop.log)"
done
echo
if ps -eo pid,args | grep -q '[c]ircusd'; then
  echo "WARNING: circus processes still running:"
  ps -eo pid,args | grep '[c]ircusd'
  note "WARNING: circusd still running after daemon stop"
else
  echo "no circus processes left"
  note "all daemons stopped"
fi
fi

# -------------------------------------------------------------- 3. datadir
if (( ! SKIP_DATADIR )); then
phase "3/6  PostgreSQL data directory, the BEFORE reading"
bash "$HERE/pg-datadir-check.sh" 2>&1 | tee "$OUT/pg-datadir-before.txt"
note "datadir before: $(sudo -n -u postgres psql -X -Atc 'SHOW data_directory;' 2>/dev/null)"
fi

# -------------------------------------------------------------- 4. collect
if (( ! SKIP_COLLECT )); then
phase "4/6  config collection (pip freeze, /etc, package state, pg globals)"
OUT="$OUT" bash "$HERE/weekend-prep.sh" 2>&1 | tee "$OUT/collect.txt"
note "config collected"
fi

# -------------------------------------------------------------- 5. restore
# Before the dumpall on purpose: it is quick, and it is the check that has
# never been run. No point spending hours on a dump if a restore does not work.
if (( ! SKIP_RESTORE )); then
phase "5/6  restore test (proves a db.psql is actually usable)"
bash "$HERE/restore-test.sh" 2>&1 | tee "$OUT/restore-test.txt"
if grep -q 'ERROR' "$OUT/restore-test.txt"; then
  note "RESTORE TEST reported errors, read $OUT/restore-test.txt"
else
  note "restore test clean"
fi
fi

# -------------------------------------------------------------- 6. dumpall
if (( ! SKIP_DUMPALL )); then
phase "6/6  full pg_dumpall (long)"
bash "$HERE/pg-dumpall-full.sh" 2>&1 | tee "$OUT/pg-dumpall.txt"
if grep -q 'ends with the completion marker' "$OUT/pg-dumpall.txt"; then
  note "pg_dumpall complete and verified"
else
  note "PG_DUMPALL did not verify, read $OUT/pg-dumpall.txt"
fi
fi

# -------------------------------------------------------------- summary
phase "summary"
printf '%s\n' "${SUMMARY[@]}"
echo
echo "finished : $(date -Is)"
echo "output   : $OUT"
echo
echo "Console: Raritan KVM (ohsa-kvm.mgt.psi.ch) is the working console but the"
echo "192.168.8.x management network is unreachable. Request pending with PSI."
echo "Mitigation in place: sshd on port 1022 tested reachable, plus tmux."
echo "Remaining uncovered risk: the machine not coming back from the reboot."
echo
echo "Next: netplan-fix-procedure.md, then reboot, then do-release-upgrade."
