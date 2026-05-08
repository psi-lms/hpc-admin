#!/bin/bash
# /usr/local/sbin/cluster-health-check.sh
#
# Monthly audit of cluster state. Writes a timestamped report to
# /var/log/cluster-health/. Drift, disk pressure, and slurm/beegfs
# weirdness show up as "## ..." sections. Exit code is always 0;
# operator is expected to read the log, not parse exit codes.
#
# Designed to run on lms-mgmt (has slurm + beegfs visibility).
# Most checks query shared filesystems, so location is not strict.

set +e

LOG_DIR=/var/log/cluster-health
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
LOG="$LOG_DIR/health-$TIMESTAMP.log"

mkdir -p "$LOG_DIR"

exec >"$LOG" 2>&1

echo "=== cluster health report — $(date -Iseconds) ==="
echo "host: $(hostname)"
echo

echo "## 1. /mnt/home group drift (expect lms or msd; flag others)"
ls -ld /mnt/home/*/ 2>/dev/null \
  | awk '$4 != "lms" && $4 != "msd" && $4 != "root" {printf "  %-15s %-15s %s\n", $3, $4, $NF}'
echo

echo "## 2. /scratch group drift"
ls -ld /scratch/*/ 2>/dev/null \
  | awk '$4 != "lms" && $4 != "msd" && $4 != "root" {printf "  %-15s %-15s %s\n", $3, $4, $NF}'
echo

echo "## 3. orphaned home dirs (may not be in puppet aaa::users any longer)"
echo "    NOTE: cross-check against compute_cluster.yaml manually; this just lists"
echo "    accounts that have files older than the last 90 days and no recent activity."
find /mnt/home -mindepth 1 -maxdepth 1 -type d -mtime +90 2>/dev/null \
  | sort | sed 's/^/  /'
echo

echo "## 4. /mnt/home — top 10 disk users (volume is 1 TB total)"
du -sh /mnt/home/*/ 2>/dev/null | sort -h | tail -10 | sed 's/^/  /'
echo

echo "## 5. /mnt/home and /scratch — free space"
df -h /mnt/home /scratch | sed 's/^/  /'
echo

echo "## 6. /scratch/containers (rootless podman storage) — per-user usage"
du -sh /scratch/containers/*/ 2>/dev/null | sort -h | sed 's/^/  /' || echo "  (empty or not yet created)"
echo

echo "## 7. Slurm — drained/down/failed nodes (sinfo -R)"
sinfo -R 2>&1 | sed 's/^/  /'
echo

echo "## 8. Slurm — partition state summary"
sinfo -o '%P %a %l %D %t' 2>&1 | sed 's/^/  /'
echo

echo "## 9. Slurm — pending jobs older than 1 hour (queueing pressure)"
squeue -h -t PD -o '%i %u %P %r %V' 2>&1 \
  | awk '{ cmd="date -d \"" $5 "\" +%s"; cmd | getline t; close(cmd);
           now=systime(); if (now-t > 3600) print "  " $0 }'
echo

echo "## 10. BeeGFS — meta server reachability"
beegfs-ctl --listnodes --nodetype=meta --reachable 2>&1 | sed 's/^/  /'
echo

echo "## 11. BeeGFS — storage target state"
beegfs-ctl --listtargets --state 2>&1 | sed 's/^/  /'
echo

echo "## 12. BeeGFS — free capacity"
beegfs-df 2>&1 | sed 's/^/  /'
echo

echo "## 13. Last puppet run summary on this host"
if [ -r /opt/puppetlabs/puppet/cache/state/last_run_summary.yaml ]; then
  awk '/^  events:/{p=1} /^  [a-z]/{if(!p)next} p && /^[a-z]/{p=0}
       /last_run|version|events|resources/' \
    /opt/puppetlabs/puppet/cache/state/last_run_summary.yaml \
    | sed 's/^/  /'
else
  echo "  (last_run_summary.yaml not readable; puppet agent may not have run)"
fi
echo

echo "=== end of report ==="

# Convenience: a stable symlink to the most recent report.
ln -snf "$(basename "$LOG")" "$LOG_DIR/latest.log"

# Convenience: a tight one-page "drift only" file for quick scanning.
{
  echo "drift summary — $(date -Iseconds)"
  echo
  echo "home dirs with non-lms/msd group:"
  ls -ld /mnt/home/*/ 2>/dev/null \
    | awk '$4 != "lms" && $4 != "msd" && $4 != "root" {print "  " $3, $4}'
  echo
  echo "scratch dirs with non-lms/msd group:"
  ls -ld /scratch/*/ 2>/dev/null \
    | awk '$4 != "lms" && $4 != "msd" && $4 != "root" {print "  " $3, $4}'
  echo
  echo "drained or down slurm nodes:"
  sinfo -R 2>/dev/null | tail -n +2 | sed 's/^/  /'
} > "$LOG_DIR/latest-drift.txt"

exit 0
