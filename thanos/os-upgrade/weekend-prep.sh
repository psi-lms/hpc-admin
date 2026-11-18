#!/usr/bin/env bash
# Cheap pre-upgrade collection. Minutes, not hours. Nothing destructive.
# Needs a primed sudo timestamp on a TTY:
#   ssh -t thanos ; sudo -v && bash ~/scripts/thanos/weekend-prep.sh
set -uo pipefail
export LC_ALL=C
cd /   # postgres cannot chdir into /home/aiida; avoids a warning per command

OUT="${OUT:-/nfs/nfsbackup/aiida_thanos/_system-config/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
# keep aiida-backup-checker.py from crashing on a dir with no backup.log
: > "$(dirname "$OUT")/backup.log"

echo "collecting into $OUT"

echo "== pip freeze per venv (this is what makes the Phase 7 rebuild faithful)"
mkdir -p "$OUT/venvs"
for v in "$HOME"/.aiida_venvs/*/bin/python; do
  [[ -x "$v" ]] || continue
  proj=$(basename "$(dirname "$(dirname "$v")")")
  "$v" -m pip freeze > "$OUT/venvs/$proj.txt" 2>/dev/null
  cp "$(dirname "$(dirname "$v")")/pyvenv.cfg" "$OUT/venvs/$proj.pyvenv.cfg" 2>/dev/null
  printf '  %-22s %s packages\n' "$proj" "$(wc -l < "$OUT/venvs/$proj.txt")"
done

echo "== which interpreter each venv is built on (decides whether Phase 7 is real)"
for c in "$HOME"/.aiida_venvs/*/pyvenv.cfg; do
  printf '%-22s %s\n' "$(basename "$(dirname "$c")")" "$(grep -E '^(home|version)' "$c" | tr '\n' ' ')"
done | tee "$OUT/venv-interpreters.txt"

echo "== package selections and system state"
dpkg --get-selections            > "$OUT/dpkg-selections.txt"
apt-mark showmanual              > "$OUT/apt-manual.txt"
apt-mark showhold                > "$OUT/apt-hold.txt"
snap list                        > "$OUT/snap-list.txt"
snap services                    > "$OUT/snap-services.txt" 2>&1
crontab -l                       > "$OUT/crontab-aiida.txt"
systemctl list-unit-files --state=enabled --no-pager > "$OUT/systemd-enabled.txt"
cp /etc/auto.master /etc/auto.nfs "$OUT/" 2>/dev/null
cp /etc/fstab "$OUT/" 2>/dev/null

echo "== /etc tarball"
sudo -n tar czf "$OUT/etc.tgz" /etc 2>/dev/null && du -h "$OUT/etc.tgz"

echo "== postgres globals (roles, tablespaces: the bit per-DB dumps miss)"
sudo -n -u postgres pg_dumpall --globals-only | gzip > "$OUT/pg-globals.sql.gz"
du -h "$OUT/pg-globals.sql.gz"

echo "== database inventory, and which databases no profile references"
sudo -n -u postgres psql -X -Atc \
  "SELECT datname, pg_database_size(datname), pg_size_pretty(pg_database_size(datname))
   FROM pg_database WHERE datallowconn ORDER BY pg_database_size(datname) DESC;" \
  > "$OUT/pg-databases.txt"
cat "$OUT/pg-databases.txt"

python3 - "$OUT" <<'PY'
import json, glob, sys, pathlib
out = pathlib.Path(sys.argv[1])
known = set()
for cfg in glob.glob('/home/aiida/project/*/.aiida/config.json') + ['/home/aiida/.aiida/config.json']:
    try:
        d = json.load(open(cfg))
    except Exception:
        continue
    for p in (d.get('profiles') or {}).values():
        n = (p.get('storage') or {}).get('config', {}).get('database_name')
        if n:
            known.add(n)
live = [l.split('|')[0] for l in (out / 'pg-databases.txt').read_text().splitlines() if l]
orphans = [d for d in live if d not in known and d not in ('postgres', 'template0', 'template1')]
(out / 'pg-orphan-databases.txt').write_text('\n'.join(orphans) + '\n')
print(f'\n{len(known)} databases referenced by a profile')
print(f'{len(orphans)} databases referenced by NO profile:')
for o in orphans:
    print(f'  {o}')
print('\nThese have no db.psql anywhere. Dump them individually if they matter:')
print('  sudo -u postgres pg_dump -Fc -f <dest>/<db>.dump <db>')
PY

echo
echo "done: $OUT"
