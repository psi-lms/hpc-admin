# Thanos

`thanos` is the group's AiiDA workstation, separate from the Thor cluster that
the rest of this repository covers. It runs Ubuntu 24.04, PostgreSQL 16, and 36
AiiDA profiles across ~20 project directories under `/home/aiida`.

This directory is the curated residue of the August 2026 upgrade from 22.04 to
24.04, kept so that **the next person to upgrade this machine can start from
here instead of from nothing**. The scripts written for that one occasion and
since spent were left out; everything here is either reusable or is the record
of a decision.

Scripts here run **on thanos**, unlike the rest of this repository, which runs
from a workstation and fans out to the cluster with `pdsh`. Deploy them to
`~/scripts/thanos/` on the box.

## Layout

| Directory | Holds |
|---|---|
| [`os-upgrade/`](os-upgrade/) | An account of the 2026 run, preparation, post-reboot checks, venv rebuilds, and what was deliberately left undone |
| [`backups/`](backups/) | The `/home/aiida` backup, the per-profile backup crontab and its preflight, and the restore test |
| [`postgres/`](postgres/) | Where the cluster keeps its data, and the whole-cluster dump |
| [`profiles/`](profiles/) | Which profile keeps its repository where, the profile inventory sweep, a functional smoke test, and a worked archive export |

## Start here

| For | Read |
|---|---|
| Upgrading the OS again | [`os-upgrade/README.md`](os-upgrade/README.md), then the sequence below |
| What was deliberately left undone | [`os-upgrade/followups.md`](os-upgrade/followups.md) |
| The `/home/aiida` backup | [`backups/home-backup.md`](backups/home-backup.md) |
| Which profile keeps its repository where | [`profiles/repository-map.md`](profiles/repository-map.md) |
| Exporting a large archive for someone | [`profiles/archive-export-runbook.md`](profiles/archive-export-runbook.md) |

## The hard-won facts

Read these before planning anything. Each one cost time to learn.

* **File count, not bytes, is the constraint on this machine.** `/home/aiida`
  held 12.9M files. Over NFSv3 every file is a round trip, so any operation
  that touches all of them (`rsync`, `du`, `rm -rf`) takes days rather than
  hours. Two trees were ~95% of the count: `project/*/local_workdir/` (13.2M
  files) and `mc3d-source/scripts/cif-export/` (3.73M).
* **Do not try to size such a tree.** `du -sh` and `diskus` both appear to hang
  on it. Watch `df -BG` deltas instead. `df -H` rounds a 29 TB volume to 0.1 TB
  and hides all progress.
* **`verdi` from a newer aiida-core silently migrates `.aiida/config.json`** to
  a newer schema, after which the intended version refuses to read it. No
  prompt, no warning. `os-upgrade/rebuild-venv.sh` and
  `profiles/storage-info-sweep.sh` both check the installed version before
  invoking `verdi` for exactly this reason.
* **`sudo` timestamps are cached per-TTY on Ubuntu**, so `ssh host 'sudo ...'`
  never works. Prime with `sudo -v` on the same TTY first.
* **A command run under `sudo -u <service>` writes as that service's user**,
  which fails on NFS paths. Redirect instead: `psql < dump`, not `psql -f
  dump`; `rabbitmqctl export_definitions -`, not a path.
* **`/nfs/nfsbackup` is exported with `root_squash`.** Root on thanos maps to
  an unprivileged uid on the filer, so `sudo` does not defeat a permission
  denial there. If the owning uid is not yours, it needs that user or PSI
  central computing.
* **Unlink permission comes from write+execute on the containing directory**,
  not from ownership of the file. A tree of mode `0550` directories cannot be
  removed by its own owner until the directories get `u+w`.
* **There was no console.** The management subnet is unreachable from every
  host we can use, and the gateways the lab wiki documents no longer resolve.
  The 2026 upgrade was completed without a console. Request access *before* the
  next one.

## Storage layout

| Mount | Purpose | Size |
|---|---|---|
| `/home` | `/dev/sda`. Live profiles, repositories, file repositories | 27 TB |
| `/nfs/nfsbackup` | Backup target (`thanosbackup` volume). **No snapshots, no SnapMirror** | 29 TB |
| `/nfs/aiida_data` | Repositories for four profiles. 132 snapshots, daily SnapMirror. **Only copy of this data** | 17 TB |
| `/` | `/dev/sdb2`, OS only | 234 GB |

Both NFS mounts are volumes on a single NetApp SVM. The volume
holding every AiiDA backup is the one with no snapshot protection, and it
shares a filer with the live data it protects. Raised with PSI central
computing on 2026-09-15; **no reply as of 2026-11-18**.

## Upgrade sequence, as actually performed

1. [`os-upgrade/weekend-prep.sh`](os-upgrade/weekend-prep.sh) — collection
   step. `pip freeze` per venv, `/etc` tarball, package state, PostgreSQL
   globals. This output is the only way to reconstruct an environment
   afterwards, so keep it.
2. [`os-upgrade/monday-prep.sh`](os-upgrade/monday-prep.sh) — the orchestrator
   that drives the above and checks the machine is fit to upgrade.
3. [`postgres/pg-datadir-check.sh`](postgres/pg-datadir-check.sh) — where
   PostgreSQL actually keeps data, including `conf.d` overrides, symlinks and
   tablespaces. Run before assuming anything about the cluster's location.
4. [`postgres/pg-dumpall-full.sh`](postgres/pg-dumpall-full.sh) —
   whole-cluster dump, verifying the gzip and the completion marker. The belt
   to the per-profile braces.
5. [`backups/home-backup.sh`](backups/home-backup.sh) — the `/home/aiida`
   content the per-profile backups do not cover. See
   [`backups/home-backup.md`](backups/home-backup.md).
6. `do-release-upgrade`. It does not touch `/home`.
7. [`os-upgrade/post-reboot.sh`](os-upgrade/post-reboot.sh) — services, autofs
   NFS mounts, and a write test on the backup target.
8. [`os-upgrade/rebuild-venv.sh`](os-upgrade/rebuild-venv.sh) +
   [`overrides.txt`](os-upgrade/overrides.txt) — rebuild one project venv on a
   given Python, reusing the editable checkouts already on disk. `NO_DEPS=1`
   reproduces a freeze verbatim when the original environment was itself
   inconsistent, which several were.
9. [`profiles/storage-info-sweep.sh`](profiles/storage-info-sweep.sh) — `verdi
   storage info` for every profile, with the version guard. Confirms nothing
   was lost.
10. [`profiles/smoke-test.py`](profiles/smoke-test.py) — `verdi run` it in any
    profile: writes nodes, then reads files back out of pre-existing ones.
11. [`backups/restore-test.sh`](backups/restore-test.sh) — restore one
    `db.psql` into a scratch database and diff the entity counts against the
    live profile. The only thing that proves the backups are restorable.
    **Worth running periodically, not just at upgrades.**
12. [`backups/crontab-preflight.sh`](backups/crontab-preflight.sh) +
    [`crontab.txt`](backups/crontab.txt) — restore the backup crontab and check
    every project has a venv and every named profile exists. Run the preflight
    whenever the crontab changes.

[`backups/run-all-backups.sh`](backups/run-all-backups.sh) runs all 19 backup
jobs sequentially, now rather than on schedule, which is what you want right
after an upgrade.

## Known weaknesses in the backup system

Carried over from [`os-upgrade/followups.md`](os-upgrade/followups.md), still
true:

* **`aiida-backup-checker.py` reports a crash as absence.** It only matches
  `Success`/`Failure`, so a traceback removes a project from the table rather
  than flagging it red. This is how one profile went unnoticed for months.
* **The profile list is hardcoded in the crontab.** `aiida-backup.sh` derives
  it from `verdi profile list` when `-p` is omitted. Pinning one profile per
  cron line is why 28 of 41 profiles were unprotected until 2026-08-20, and
  nothing warns when a new profile appears.
* **`verdi storage backup` runs maintenance, which fails on a profile being
  written to.** Any profile busy at its cron slot can fail this way.
* **The crontab is versioned nowhere else.** `backups/crontab.txt` here is a
  snapshot, not the live state.
