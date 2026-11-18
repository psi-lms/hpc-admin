#!/usr/bin/env bash
# Full cluster dump: every database plus roles, tablespaces and globals.
# Redundant with the per-profile db.psql files for the 36 profile databases,
# but it is the only thing that captures databases no profile references, and
# it is a single self-contained artefact to restore from.
#
#   sudo -v && bash ~/scripts/hpc-admin/thanos/postgres/pg-dumpall-full.sh
#
# Run with the AiiDA daemons stopped and the backup crontab suspended.
# pg_dumpall runs pg_dump per database sequentially, each in its own snapshot,
# so it is not a single cluster-wide consistent point. With nothing writing,
# that distinction does not matter.
set -uo pipefail
export LC_ALL=C
cd /   # postgres cannot chdir into /home/aiida; avoids a warning per command

DEST="${DEST:-/nfs/nfsbackup/aiida_thanos/_pg-dumpall}"
mkdir -p "$DEST"
: > "$DEST/backup.log"   # keeps aiida-backup-checker.py from crashing on this dir

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/pgdumpall-$STAMP.sql.gz"
LOG="$DEST/pgdumpall-$STAMP.log"

echo "== cluster contents"
sudo -n -u postgres psql -X -P pager=off -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
   FROM pg_database WHERE datallowconn
   ORDER BY pg_database_size(datname) DESC;" | tee "$LOG"

TOTAL=$(sudo -n -u postgres psql -X -Atc \
  "SELECT sum(pg_database_size(datname)) FROM pg_database;")
echo "cluster total: $(numfmt --to=iec "$TOTAL")" | tee -a "$LOG"

echo
echo "== destination"
df -h "$DEST" | tail -1 | tee -a "$LOG"
echo "writing to $OUT"
echo

echo "== still writing? (should be empty)"
ps -eo pid,args | grep -E '[c]ircusd|[v]erdi' || echo "  nothing running, good"
echo

echo "== dumping (hours, depending on cluster size)"
t0=$SECONDS
sudo -n -u postgres pg_dumpall --clean --if-exists 2>>"$LOG" | gzip -c > "$OUT"
rc=${PIPESTATUS[0]}
dt=$(( SECONDS - t0 ))

echo
echo "pg_dumpall exit code: $rc, took ${dt}s" | tee -a "$LOG"
ls -lh "$OUT" | tee -a "$LOG"

if (( rc != 0 )); then
  echo "FAILED. See $LOG" | tee -a "$LOG"
  exit "$rc"
fi

echo
echo "== verifying the archive is readable end to end"
if gzip -t "$OUT"; then
  echo "gzip integrity OK" | tee -a "$LOG"
else
  echo "GZIP CORRUPT" | tee -a "$LOG"; exit 1
fi

# A truncated dump still gunzips. The completion marker is the only real proof
# it finished writing. Note the wording: pg_dumpall writes "... database CLUSTER
# dump complete", pg_dump writes "... database dump complete". Matching the
# wrong one gives a false truncation warning on a perfectly good dump.
echo "last lines of the dump:" | tee -a "$LOG"
zcat "$OUT" | tail -3 | tee -a "$LOG"
if zcat "$OUT" | tail -5 | grep -q 'PostgreSQL database cluster dump complete'; then
  echo "OK: dump ends with the completion marker" | tee -a "$LOG"
else
  echo "WARNING: no completion marker, the dump may be truncated" | tee -a "$LOG"
fi

echo
echo "== databases captured"
zcat "$OUT" | grep -c '^CREATE DATABASE' | xargs echo "CREATE DATABASE statements:" | tee -a "$LOG"
echo "done: $OUT"
