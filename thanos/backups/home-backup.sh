#!/usr/bin/env bash
# Rotating backup of /home/aiida to NFS, for everything the per-profile verdi
# backups do not cover: dotfiles, .ssh, .erlang.cookie, every config.json and
# setup/ YAML, scripts/, git-repos/ checkouts, notebooks. Roughly 387 GB.
#
#   bash home-backup.sh              # dry run, summary only
#   bash home-backup.sh --top 25     # dry run, plus the 25 largest candidates
#   bash home-backup.sh --go         # copy
#
# Self-contained: the exclude list is embedded below, so this one file is the
# whole deployment. Run it on thanos as the `aiida` user.
#
# Schedule: weekly, Sunday 05:30, keeping 4 generations (~1 month of depth).
# The 19 per-profile jobs occupy 00:00 to 04:30, and `verdi storage backup`
# runs a maintenance step that already fails on an active profile, so
# overlapping them is worth avoiding. /home/aiida outside the profiles is
# config, code and notebooks, which change slowly; daily generations would
# cost inodes and prune time without buying recovery depth.
#
#   30 5 * * 0 /bin/bash /home/aiida/scripts/hpc-admin/thanos/backups/home-backup.sh --go >> /home/aiida/home-backup-cron.log 2>&1
#
# Do NOT wrap that in an outer `flock` on the same lock path: the wrapper would
# take the lock and this script would then find it held and exit immediately.
#
# Design notes and open items: home-backup.md
set -uo pipefail
export LC_ALL=C

SRC="${SRC:-/home/aiida}"
DEST_ROOT="${DEST_ROOT:-/nfs/nfsbackup/aiida_thanos/_home-aiida}"
KEEP="${KEEP:-4}"
# 1 TB, against ~5.4 TB free. Generous on purpose: the per-profile verdi
# backups share this volume and must not be starved by this one.
MIN_FREE_GB="${MIN_FREE_GB:-1000}"
LOCK="${LOCK:-/tmp/home-backup.lock}"
STAGE="$DEST_ROOT/in-progress"

GO=0
TOP=0
while (( $# )); do
  case "$1" in
    --go)    GO=1; shift ;;
    --top)   TOP="${2:?--top needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Exclude list
# ---------------------------------------------------------------------------
# Paths are relative to $SRC. Written to a temp file at run time so this script
# stays a single deployable file.
#
# Nothing here is deleted from /home. Excluding a path is reversible, deleting
# it is not, which is why this list needed no owner sign-off while the cleanup
# decisions were still outstanding. If an owner later confirms a tree is
# disposable, that is a separate `rm`, not an edit here.
#
# The binding constraint is FILE COUNT, not bytes: over NFSv3 every file is a
# round trip, and the pre-upgrade full copy was 12.9M files and could not
# finish in a night. `local_workdir` and `cif-export` are ~95% of that count.
EXCLUDES=$(cat <<'EOF'
# --- covered by the per-profile verdi backups (container + db.psql) ---
# Three repository layouts are in use; see ../profiles/repository-map.md.
project/*/.aiida/repository/
project/*/repositories/
*.psql
*.sql
*.sqlite
*.sqlite3
*.dump

# --- raw calculation files: inputs/outputs of jobs already in the profiles ---
# 13.2M files / 542 GB in mc3d-source alone. `verdi calcjob cleanworkdir`
# reclaims these on disk too, once owners confirm.
**/local_workdir/
project/*/workdir/
**/_scratch/
**/*.save/
**/*.wfc[0-9]*
**/*.mix[0-9]*

# --- archive exports: regenerable with `verdi archive create` ---
# ~1.5 TB in 649 files, ~360 GB of it same-named duplicates in the top 10.
*.aiida

# --- generated bulk data, regenerable from the profiles ---
# 3.73M files / 75 GB.
project/mc3d-source/scripts/cif-export/

# --- Python / JS environments: derived artefacts, not data ---
# An environment is recreatable from the lockfile and pyproject that define it,
# which are themselves in the checkouts under git-repos/ and so are backed up.
# Restoring 551k installed files to avoid a `uv sync` is the wrong trade,
# especially over NFS where the file count is what costs.
.aiida_venvs/
**/.venv/
**/venv/
**/site-packages/
**/node_modules/
**/__pycache__/
**/*.pyc
**/*.pyo
**/*.egg-info/
miniconda3/
.conda/pkgs/
.local/share/uv/
.npm/
.cargo/registry/
.cargo/git/
.rustup/toolchains/
.rustup/downloads/

# --- logs: one of these is 15 GB and wants rotating, not backing up ---
project/*/.aiida/daemon/log/
*.log.[0-9]*
aiida-dev.log

# --- scratch and caches ---
tmp/
.aiida_backup_tmp/
.cache/
.vscode-server/
.vscode-remote-containers/
.dotnet/
.local/share/Trash/
backup-run-*/
post-reboot-*.txt
pre-reboot-*.txt
**/.ipynb_checkpoints/
**/.mypy_cache/
**/.pytest_cache/
**/.ruff_cache/
**/.tox/
**/build/
**/dist/
**/.git/objects/pack/tmp_*
core.[0-9]*

# --- MUST be kept, listed so the decision is explicit ---
# .ssh/                         authorized_keys for every user of the box
# .erlang.cookie                RabbitMQ node auth
# .aiida/config.json            global config
# project/*/.aiida/config.json  per-project profile definitions
# project/*/setup/              computer / code / profile provisioning YAML
# scripts/                      the backup script repo and the upgrade scripts
# git-repos/                    plugin and project checkouts, incl. uncommitted
# jupyter/                      notebooks and their data (53 GB in jupyter/mm)
# icsd_raw_export/              possibly licensed, NOT regenerable
EOF
)

TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf -- "$TMPDIR_RUN"' EXIT
EXCLUDE_FILE="$TMPDIR_RUN/exclude.txt"
printf '%s\n' "$EXCLUDES" > "$EXCLUDE_FILE"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -d "$SRC" ]] || { echo "no source at $SRC" >&2; exit 1; }

# Serialise runs. Two concurrent runs would write into the same staging
# directory and fight over the same files. `flock -n` on a dedicated fd holds
# the lock for the life of this shell; a second run exits 0 rather than
# queueing, so an overlap does not mail cron about a failure.
exec {lockfd}>"$LOCK" || { echo "cannot open $LOCK" >&2; exit 1; }
if ! flock -n "$lockfd"; then
  echo "another run already holds $LOCK, exiting"
  exit 0
fi

# The previous completed generation, for --link-dest.
PREV=""
if [[ -L "$DEST_ROOT/latest" ]]; then
  PREV="$DEST_ROOT/$(readlink "$DEST_ROOT/latest")"
  [[ -d "$PREV" ]] || PREV=""
fi

# -aHAX: archive, hard links, ACLs, xattrs. -H matters: .git object stores and
# --link-dest both rely on it.
# --link-dest: unchanged files become hard links into the previous generation,
# so generation N+1 costs only what changed. Cheap in bytes, NOT in inodes:
# each generation is a complete directory tree, so raising KEEP multiplies
# directory entries and makes pruning slower. It also means deleting one
# generation frees only the blocks no surviving generation links to.
# No -z: local-to-NFS, and most remaining bytes are already compressed.
RSYNC=(rsync -aHAX --partial --exclude-from="$EXCLUDE_FILE")
[[ -n "$PREV" ]] && RSYNC+=(--link-dest="$PREV")

echo "src       : $SRC"
echo "dest      : $DEST_ROOT"
echo "link-dest : ${PREV:-none (first generation)}"
echo "keep      : $KEEP generations"

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
if (( ! GO )); then
  echo
  echo ">>> DRY RUN, nothing is written. Re-run with --go to copy."
  echo ">>> This still stats every candidate file over NFS, so expect it to"
  echo ">>> sit quiet for a long time before the summary appears."
  echo

  # One traversal only. Per-file output goes to a temp file rather than the
  # terminal; the summary and the optional top-N are both derived from it.
  LIST="$TMPDIR_RUN/candidates.txt"
  "${RSYNC[@]}" --dry-run --out-format='%l %n' "$SRC/" "$STAGE/" >"$LIST" 2>"$TMPDIR_RUN/err"
  rc=$?
  if (( rc != 0 && rc != 24 )); then
    echo "rsync exited $rc:" >&2
    tail -5 "$TMPDIR_RUN/err" >&2
    exit "$rc"
  fi

  # Directories carry a trailing slash in --out-format='%n' and their listed
  # size is just the directory inode, so they are counted but not summed.
  awk '
    NF >= 2 && $1 ~ /^[0-9]+$/ {
      if ($2 ~ /\/$/) { dirs++; next }
      files++; bytes += $1
    }
    END {
      printf "SUMMARY\n"
      printf "  files to transfer : %d\n", files
      printf "  directories       : %d\n", dirs
      printf "  total file size   : %.2f GiB\n", bytes / 1073741824
      printf "\n"
      printf "  File count is what decides whether the run finishes in one\n"
      printf "  sitting, and how many generations KEEP can afford.\n"
    }
  ' "$LIST"

  if (( TOP > 0 )); then
    echo
    echo "LARGEST $TOP CANDIDATES"
    awk 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 !~ /\/$/ {print}' "$LIST" \
      | sort -rn | head -n "$TOP" \
      | numfmt --field=1 --to=iec --padding=12 \
      | sed 's/^/  /'
    echo
    echo "Anything large here that you expected to be filtered means the"
    echo "exclude list has a gap."
  else
    echo
    echo "Re-run with --top 25 to see the largest candidates."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------
# /nfs/nfsbackup has no snapshots and no SnapMirror, so this rotation is the
# only recovery depth that exists. Refuse to start a run that could fill it.
avail=$(df -BG --output=avail "$DEST_ROOT" | tail -1 | tr -dc '0-9')
if (( avail < MIN_FREE_GB )); then
  echo "only ${avail}G free on $DEST_ROOT, below MIN_FREE_GB=${MIN_FREE_GB}G" >&2
  echo "prune a generation, or raise MIN_FREE_GB deliberately" >&2
  exit 1
fi

LOG="$HOME/home-backup-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$STAGE"

# aiida-backup-checker.py does os.listdir() on aiida_thanos/ and opens
# <dir>/backup.log with no error handling. An empty one keeps it from crashing
# on this directory. "_home-aiida" still belongs in its EXCLUDE_DIRS properly.
: > "$DEST_ROOT/backup.log"

{
  echo "started : $(date -Is)"
  df -BG "$DEST_ROOT" | tail -1
} | tee -a "$LOG"

# Staged into in-progress/ and promoted only on success, so a partial copy can
# never be mistaken for a complete one. Re-running continues where it stopped.
"${RSYNC[@]}" --info=progress2,stats2 --human-readable "$SRC/" "$STAGE/" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}

{
  echo
  echo "finished : $(date -Is)"
  echo "rsync exit code: $rc"
} | tee -a "$LOG"

# 0 = clean, 24 = source files vanished mid-run, expected on a live box.
if (( rc != 0 && rc != 24 )); then
  echo "INCOMPLETE. Left staged at $STAGE; re-run to continue." | tee -a "$LOG"
  exit "$rc"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
mv "$STAGE" "$DEST_ROOT/$STAMP"
ln -sfn "$STAMP" "$DEST_ROOT/latest"
echo "COMPLETE: $DEST_ROOT/$STAMP  (latest -> $STAMP)" | tee -a "$LOG"

# Prune the oldest generations beyond KEEP. Timestamp names sort
# chronologically, so lexical order is chronological order.
mapfile -t gens < <(find "$DEST_ROOT" -maxdepth 1 -mindepth 1 -type d \
  -name '[0-9]*-[0-9]*' -printf '%f\n' | sort)
if (( ${#gens[@]} > KEEP )); then
  for old in "${gens[@]:0:$(( ${#gens[@]} - KEEP ))}"; do
    echo "pruning $DEST_ROOT/$old" | tee -a "$LOG"
    rm -rf -- "${DEST_ROOT:?}/${old:?}"
  done
fi

df -BG "$DEST_ROOT" | tail -1 | tee -a "$LOG"
