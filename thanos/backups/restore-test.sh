#!/usr/bin/env bash
# Restore one db.psql into a scratch database and count what came back.
# This is the step that has never been tested, and it is the entire premise
# of the backup. Read-only against the backup; creates and drops one scratch DB.
#
#   sudo -v && bash ~/scripts/hpc-admin/thanos/backups/restore-test.sh
#   PROJECT=sssp-tests PROFILE=correct_cutoffs bash ~/scripts/hpc-admin/thanos/backups/restore-test.sh
set -uo pipefail
export LC_ALL=C
# sudo keeps the cwd, and postgres cannot chdir into /home/aiida (drwxr-x---).
# Harmless, but it prints a warning before every command. Move somewhere neutral.
cd /

PROJECT="${PROJECT:-electrides_test}"   # 302 MB dump: big enough to be real, small enough to be quick
PROFILE="${PROFILE:-presto}"
SRC="/nfs/nfsbackup/aiida_thanos/$PROJECT/$PROFILE/last-backup/db.psql"
DB="restore_test_$(date +%Y%m%d_%H%M%S)"

[[ -f "$SRC" ]] || { echo "no dump at $SRC"; exit 1; }
echo "dump   : $SRC  ($(du -h "$SRC" | cut -f1))"
echo "scratch: $DB"
echo

# verdi storage backup writes --format=p, so it restores with psql, not pg_restore.
sudo -n -u postgres createdb "$DB" || exit 1
trap 'echo; echo "dropping $DB"; sudo -n -u postgres dropdb --if-exists "$DB"' EXIT

echo "restoring (errors below are what we are looking for) ..."
t0=$SECONDS
# NOT -f "$SRC": that makes the postgres user open the file, and it cannot read
# under /nfs as aiida. Redirecting means this shell opens it and psql inherits
# the descriptor.
sudo -n -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" < "$SRC" 2>&1 \
  | grep -vE '^(SET|CREATE|ALTER|GRANT|COMMENT|COPY)' | head -40
echo "restore took $(( SECONDS - t0 ))s"
echo

echo "== what came back"
sudo -n -u postgres psql -X -d "$DB" -c "
  SELECT 'nodes' AS what, count(*) FROM db_dbnode
  UNION ALL SELECT 'links', count(*) FROM db_dblink
  UNION ALL SELECT 'users', count(*) FROM db_dbuser
  UNION ALL SELECT 'groups', count(*) FROM db_dbgroup
  UNION ALL SELECT 'computers', count(*) FROM db_dbcomputer;"

echo "== compare against the live database"
LIVE=$(python3 -c "
import json
d=json.load(open('/home/aiida/project/$PROJECT/.aiida/config.json'))
print(d['profiles']['$PROFILE']['storage']['config']['database_name'])")
echo "live database: $LIVE"
sudo -n -u postgres psql -X -d "$LIVE" -c "
  SELECT 'nodes' AS what, count(*) FROM db_dbnode
  UNION ALL SELECT 'links', count(*) FROM db_dblink
  UNION ALL SELECT 'users', count(*) FROM db_dbuser
  UNION ALL SELECT 'groups', count(*) FROM db_dbgroup
  UNION ALL SELECT 'computers', count(*) FROM db_dbcomputer;"

echo
echo "The two tables should match, allowing for anything written since the backup ran."
