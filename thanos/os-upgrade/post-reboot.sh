#!/usr/bin/env bash
# Verify thanos came back correctly. Read-only.
#
#   bash /tmp/post-reboot.sh 2>&1 | tee ~/post-reboot-$(date +%F-%H%M).txt
set -uo pipefail
export LC_ALL=C
sec() { printf '\n\n===== %s =====\n' "$*"; }

sec "WHEN"
date -Is; uptime; uname -r
ls -l /var/run/reboot-required* 2>/dev/null || echo "no reboot pending (good)"

sec "ANYTHING FAILED"
systemctl --failed --no-pager
echo "--- errors this boot ---"
journalctl -p err -b --no-pager | tail -40

sec "MEMORY AND SWAP (compare against pre-reboot)"
free -h
swapon --show

sec "SERVICES BACK UP"
for u in postgresql rabbitmq-server cron autofs docker snap.microk8s.daemon.containerd; do
  printf '%-36s %-10s %s\n' "$u" "$(systemctl is-enabled "$u" 2>&1)" "$(systemctl is-active "$u" 2>&1)"
done

sec "POSTGRES"
pg_lsclusters
ss -tlnp 2>/dev/null | grep -E ':5432|:5672' || echo "NOTHING LISTENING on 5432/5672"

sec "MOUNTS, INCLUDING AUTOFS NFS"
findmnt -t ext4,vfat -o TARGET,SOURCE,FSTYPE,SIZE,AVAIL,USE%
# autofs mounts on demand, so touch both shares to prove they still work
ls -d /nfs/nfsbackup /nfs/aiida_data >/dev/null 2>&1
df -hT /nfs/nfsbackup /nfs/aiida_data

sec "BACKUP DESTINATION STILL WRITABLE"
t=/nfs/nfsbackup/aiida_thanos/.write-test-$$
if touch "$t" 2>/dev/null; then rm -f "$t"; echo "OK: /nfs/nfsbackup writable"; else echo "FAIL: cannot write to /nfs/nfsbackup"; fi

sec "CRONTAB SURVIVED"
crontab -l | grep -c aiida-backup.sh
echo "(expect 20: 19 entries plus one comment mention)"

sec "AIIDA DAEMONS (expect none until started deliberately)"
ps -eo pid,etime,args | grep -E '[c]ircusd' || echo "(none running)"

sec "END"
date -Is
