#!/usr/bin/env bash
# Where does PostgreSQL actually keep its data, and which partition is that on?
# Run before the upgrade, after installing 16, and after pg_upgradecluster.
# Read-only.
#
#   sudo -v && bash ~/scripts/thanos/pg-datadir-check.sh
set -uo pipefail
export LC_ALL=C
cd /   # postgres cannot chdir into /home/aiida; avoids a warning per command
hr() { printf '\n--- %s\n' "$*"; }

hr "clusters (Data directory column is the quick answer)"
pg_lsclusters

hr "what each RUNNING server reports (authoritative)"
for port in $(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online"{print $3}'); do
  echo "port $port:"
  sudo -n -u postgres psql -X -p "$port" -Atc \
    "SELECT 'data_directory = ' || setting FROM pg_settings WHERE name='data_directory'
     UNION ALL SELECT 'config_file    = ' || setting FROM pg_settings WHERE name='config_file'
     UNION ALL SELECT 'hba_file       = ' || setting FROM pg_settings WHERE name='hba_file'
     UNION ALL SELECT 'server_version = ' || setting FROM pg_settings WHERE name='server_version';" \
    | sed 's/^/  /'
done

hr "configured value, including conf.d overrides (last one wins)"
grep -rHn "^[[:space:]]*data_directory" /etc/postgresql/*/*/postgresql.conf /etc/postgresql/*/*/conf.d/*.conf 2>/dev/null
echo "(if conf.d shows a data_directory, it overrides postgresql.conf)"

hr "which filesystem each data directory sits on"
for d in $(pg_lsclusters --no-header 2>/dev/null | awk '{print $6}'); do
  printf '%s\n' "$d"
  df -hT "$d" 2>/dev/null | tail -1 | sed 's/^/  /'
  sudo -n du -sh "$d" 2>/dev/null | sed 's/^/  size: /'
done

hr "is anything a symlink? (the other way data escapes a partition)"
ls -la /var/lib/postgresql/ 2>/dev/null
ls -la /home/postgres/ /home/postgres/postgresql/ 2>/dev/null
ls -la /home/postgresql/ 2>/dev/null
for d in $(pg_lsclusters --no-header 2>/dev/null | awk '{print $6}'); do
  sudo -n ls -la "$d/pg_wal" "$d/pg_xlog" 2>/dev/null | head -3
done

hr "tablespaces (data can live outside the data directory entirely)"
sudo -n -u postgres psql -X -P pager=off -c \
  "SELECT spcname, pg_tablespace_location(oid) AS location FROM pg_tablespace;"

hr "free space on the candidate partitions"
df -hT / /home 2>/dev/null

hr "verdict"
echo "Data must live on /home (24 TiB). The root filesystem is ~218 GiB."
echo "After installing postgresql-16 the packages will create"
echo "  /var/lib/postgresql/16/main   <- ON ROOT, wrong place, and must be dropped"
echo "so pg_upgradecluster has to be given the target explicitly:"
echo "  sudo pg_upgradecluster -v 16 14 main /home/postgres/postgresql/16/main"
