# The `/home/aiida` backup on thanos

State as of 2026-11-18. Read this before touching the home backup. Background
on everything else from the 24.04 upgrade is in [`followups.md`](../os-upgrade/followups.md)
and [`../README.md`](../README.md).

## Why there is a gap at all

The per-profile `verdi` backups cover what AiiDA owns: each profile's
disk-objectstore container plus a `db.psql` dump. 19 cron jobs, 36 profiles,
00:00 to 04:30 nightly, restored 2026-09-09.

They do not cover anything else in `/home/aiida`: dotfiles, `.ssh`,
`.erlang.cookie`, the global and per-project `config.json`, the `setup/`
provisioning YAML, `scripts/`, `git-repos/` checkouts with uncommitted work,
notebooks. 174 GB in 745k files, measured on the first full run.

That content had one copy, an rsync taken before the upgrade at
`/nfs/nfsbackup/aiida_thanos/_home-aiida/20260821-152301/`: 1.84 TB,
12.9M files. It was deleted in November because 1.5 TB of it was archive
exports that users were being asked to delete anyway, and because a 12.9M-file
tree cannot be re-taken in a night. Deletion completed 2026-11-18, all 1.84 TB
reclaimed.

Between then and the first run of the new script, the non-profile contents of
`/home/aiida` had **no backup at all**. That is what this work closed.

## First run

2026-11-18, 15:54 to 16:54 UTC, one hour wall clock, rsync exit 0.

```
Number of files: 857,611 (reg: 744,797, dir: 111,254, link: 1,560)
Total file size: 173.97G bytes
```

Promoted to `/nfs/nfsbackup/aiida_thanos/_home-aiida/20261118-165444`, with
`latest` pointing at it. The volume went from 82% to 83% used.

Compare against the pre-upgrade full copy: 1.84 TB and 12.9M files, which could
not finish in a night. The exclude list is what turned days into an hour.

## Route taken, and what was rejected

Three designs were written. Only the third survives, as
[`home-backup.sh`](home-backup.sh); the other two were
dropped when this directory was assembled, and are recoverable from the notes
directory if anyone ever wants them.

1. **Two-tier.** Tier 1 config and code only, tier 2 everything, selected by a
   filter file. Abandoned during the upgrade in favour of taking one full copy,
   because the tier boundary kept needing per-project exceptions.
2. **One full copy.** Resumable and staged, and it produced the
   `20260821-152301` generation. No generations and no rotation, and its
   exclude list was written to capture everything once rather than to finish
   every run. Superseded.
3. **Rotating generations against a tight exclude list.** Current. Keeps the
   staging and resumability of the second, adds `--link-dest`, and excludes the
   two trees that made the second one unable to finish in a night.

The current script is deliberately a **single file**: the exclude list is a
heredoc inside it, written to a temp file at run time. Deploying the backup is
copying one file, and the filter can never drift out of sync with the script
that uses it.

## The constraint that drove every decision

**File count, not bytes.** The full copy was 12.9M files, and over NFSv3 every
file is a round trip, so it could not finish in one night. Two trees are ~95%
of that count:

* `project/*/local_workdir/` — 13.2M files, 542 GB, raw calculation inputs and
  outputs for jobs that are already in the backed-up profiles.
* `project/mc3d-source/scripts/cif-export/` — 3.73M files, 75 GB, regenerable.

Both are excluded. A third, `*.aiida` archive exports, is ~1.5 TB in 649 files,
regenerable with `verdi archive create`, with ~360 GB of same-named duplicates
in the top 10 alone. Also excluded.

The same reasoning applies to `du` and `diskus`: do not try to size a tree of
this shape over NFS, it will appear to hang. Watch `df -BG` deltas instead.
`df -H` rounds a 29 TB volume to 0.1 TB and hides progress.

## Cleanup is deliberately separate from the backup

No owner feedback ever arrived on the deletion list, so **nothing more has been
deleted**. Still pending an owner's OK: 1.5 TB archive exports, 542 GB
`local_workdir`, 75 GB `cif-export`, 351 GB `/home/aiida/tmp`, and
`first-hero-run-backup-2024` (487 GB, untouched since July 2024) which stays.

The principle that unblocked the work: **excluding a path from the backup is
reversible, deleting it is not.** So the exclude list was written without
needing anyone's answer. Do not conflate the two again. If an owner later says
a tree is disposable, that is a separate `rm`, not an exclude-list change.

## Current configuration

Script: [`home-backup.sh`](home-backup.sh).

* **Source**: `/home/aiida`
* **Destination**: `/nfs/nfsbackup/aiida_thanos/_home-aiida/`, timestamped
  generations plus a `latest` symlink
* **Schedule**: weekly, Sunday 05:30. The first free slot after the 19
  per-profile jobs finish at 04:30. Overlapping them is worth avoiding because
  `verdi storage backup` runs a maintenance step that already fails on an
  active profile.
* **Retention**: `KEEP=8`, so ~2 months of depth. Agreed in the group meeting
  of 2026-11-18, raised from an initial 4. Daily was considered and rejected:
  this content changes slowly, and generations cost inodes and prune time
  without buying recovery depth.
* **Opt-out directory**: `/home/aiida/no-backup/` is excluded. Created
  2026-11-18 so users have somewhere to put large scratch data without it
  entering a generation, and without this list needing an edit per case.
* **Free-space floor**: `MIN_FREE_GB=1000`. Refuses to start below 1 TB free,
  against ~5.4 TB available. Generous on purpose, because the per-profile
  backups share this volume and must not be starved.
* **Concurrency**: `flock -n` on a dedicated fd. A second run exits 0 rather
  than queueing, so an overlap does not mail cron about a failure. Do not wrap
  the cron invocation in an outer `flock` on the same path: the wrapper would
  take the lock and the script would then find it held and exit immediately.

Cron line:

```cron
30 5 * * 0 /bin/bash /home/aiida/scripts/hpc-admin/thanos/backups/home-backup.sh --go >> /home/aiida/home-backup-cron.log 2>&1
```

### Properties worth knowing before changing anything

* `--link-dest` makes a generation nearly free in **bytes**, since unchanged
  files are hard links into the previous one. It does **not** make it free in
  **inodes**: each generation is a complete directory tree. Raising `KEEP`
  multiplies directory entries and makes pruning slower.
* Because generations share blocks, deleting one frees only the blocks no
  surviving generation links to. A `du` of one generation does not tell you
  what deleting it would reclaim.
* **Pruning the oldest generation does not break the newer ones.** Hard links
  are peers: no generation is the original, and the inode's data survives until
  its link count reaches zero. `rm -rf` on generation 1 removes directory
  entries and decrements link counts; a file still referenced by generations
  2-8 keeps its blocks. Verify with `stat -c '%h %i'` on the same path across
  generations.
* The script stages into `in-progress/` and promotes to a timestamped directory
  only after rsync exits 0 or 24, so a partial copy can never be mistaken for a
  complete one. Re-running continues where it stopped.
* rsync exit 24 means source files vanished mid-run. Expected on a live box,
  treated as success.

## Open items

* **`--link-dest` is proven on this volume, not assumed.** `stat` on the
  per-profile generations shows one inode with `links=4` across four
  `mc3d-source/prod` backups, including a 4.29 GB pack file. NFSv3 has a `LINK`
  procedure that ONTAP executes server-side. The constraint `link(2)` imposes
  is one filesystem, which all generations under `/nfs/nfsbackup` satisfy.
* **`/nfs/nfsbackup` has no snapshots and no SnapMirror**, while the live
  `/nfs/aiida_data` has 132 snapshots and daily replication. The volume holding
  every AiiDA backup is the unprotected one, on the same filer as the data it
  protects. Raised with PSI central computing on 2026-09-15, **no reply**. Until that
  changes, this rotation is the only recovery depth that exists for `/home`.
* **`aiida-backup-checker.py` reports a crash as absence.** It only matches
  `Success`/`Failure`, so a traceback removes a project from the table rather
  than flagging it red. It also does `os.listdir()` on `aiida_thanos/` and
  opens `<dir>/backup.log` unguarded; the script touches an empty one to keep
  it from crashing, but `_home-aiida` belongs in its `EXCLUDE_DIRS` properly.
  As things stand, **a failing home backup would show as nothing at all.**
* **Nothing versions any of this.** The scripts live in `~/notes` and the
  crontab is versioned nowhere, which is why 28 of 41 profiles were unprotected
  until 2026-08-20. Both belong in the `aiida-backup-script` repo.
* **Restore has not been tested.** `restore-test.sh` proves the database
  backups restore; nothing equivalent has been done for this one. Worth
  restoring a handful of files from the first generation.
* `icsd_raw_export/` is deliberately **not** excluded: possibly licensed and
  not regenerable. Do not add it to the list without checking its provenance.
* The old pre-upgrade generation is gone. Its last 79 MB survived the first
  `rm -rf` because 314 `potpaw/<El>/` directories were mode `0550`; cleared
  2026-11-18 with `find ... -type d -exec chmod u+w {} +` and a second `rm`.

## Operational constraints on this machine

* `/nfs/nfsbackup` is exported with `root_squash`. Root on thanos maps to an
  unprivileged uid on the filer, so `sudo` does not defeat a permission denial
  there. If the owning uid is not yours, it needs that user or PSI central computing.
* Unlink permission comes from write+execute on the **containing directory**,
  not from ownership of the file. This is what blocked the last 79 MB of the
  old copy: 314 `potpaw/<El>/` directories at mode `0550`, owner `aiida`.
  Fixed with `find ... -type d -exec chmod u+w {} +` then `rm -rf`.
* `sudo` timestamps are cached per-TTY on Ubuntu, so `ssh host 'sudo ...'`
  never works. Prime with `sudo -v` on the same TTY.
* A command run under `sudo -u <service>` writes as that service's user, which
  fails on NFS paths. Redirect instead: `psql < dump`, not `psql -f dump`.
