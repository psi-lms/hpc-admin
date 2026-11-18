# Upgrading thanos: an account of the 2026 run

What actually happened during the August 2026 move from Ubuntu 22.04 to 24.04,
written for whoever does the next one. The full day-by-day log stays in the
maintainer's notes rather than this public repository; this is the part that
transfers.

Shape of it: 2026-08-20 planning and backups, 2026-08-24 preparation and
`do-release-upgrade`, 2026-08-25 rebuilding the 20 Python environments,
2026-09-09 restoring the backup crontab. The upgrade itself was uneventful. The
work was all before and after it.

## What took the time

Not the OS. In order of hours spent:

1. **Establishing what was already backed up.** The answer turned out to be
   "fewer profiles than anyone believed": 28 of 41 were unprotected, because
   the crontab pinned one profile per line and nothing warned when a new
   profile appeared.
2. **Copying `/home/aiida`.** 15.8 TiB and ~12.9M files, almost all of which
   the per-profile backups already covered. See
   [`../backups/home-backup.md`](../backups/home-backup.md).
3. **Rebuilding 20 project virtual environments.** Six failed on the first
   pass, for two root causes, below.

## The traps, in the order they will bite you

### A manual backup run colliding with cron

A `run-all-backups.sh` pass started mid-afternoon was still working when the
nightly cron fired, and two profiles failed in two different ways:

* One lost the race for the shared `live-backup` staging directory, and died on
  `Failed to move '.../live-backup' to '.../backup_<stamp>'`.
* One hit `FileExistsError` on `container/packs/0.lock`, raised inside
  `pack_all_loose` during the backup's own maintenance step, because the other
  process held the pack lock.

Neither corrupted anything. The pack lock refusing a second writer *is* the
protection working, and the destination is gated: `live-backup` only becomes a
generation if the final rename succeeds, so a half-written staging directory
cannot pass itself off as a good backup. Both cost hours.

**Rule: never run a manual `verdi storage backup` while cron can fire on the
same profile.** Suspend the crontab for the duration, or finish before the
first slot. The one real exposure is that two profiles keep their
disk-objectstore SQLite index on NFS, where advisory locking is unreliable;
here the second process died at lock acquisition before writing.

### Running `verdi` from the wrong aiida-core

**This is the one that did damage.** A closing `verdi status` in the rebuild
script migrated a project's `config.json` from version 9 to 10, after which the
project's own pinned aiida-core refused to read it:

```
The configuration file has version 10 which is not compatible with the current version 9
```

Cause: a failed rebuild had pulled the latest aiida-core from PyPI as a
side effect of installing an editable plugin, and `verdi` migrates the config on
load, without asking. Blast radius was one project, and AiiDA writes v9 backups
first, so recovery was a file copy.

`rebuild-venv.sh` now runs `verdi status` only when the install succeeded *and*
the installed aiida-core matches what the freeze pins. The general lesson
outlives this upgrade: **any tooling that invokes `verdi` opportunistically
against a project it did not build must check the version first.**

### Editable `aiida-core` and two-phase installs

Six of 20 venvs failed, and the correlation was exact: **all five projects with
an editable `aiida-core` failed; all ten with a plain `aiida-core==` pin
succeeded.**

Installing the pinned set first and the editables afterwards cannot work when
`aiida-core` is itself editable. The freeze pins `plumpy`, `psutil`, `pgsu` and
`asyncssh` at the versions the local checkout needs, so resolving the pinned set
alone requires a *published* aiida-core compatible with those pins, and none
exists. Fixed by resolving everything in a single `uv pip install`, so the local
checkout is available as a provider.

Three smaller ones from the same phase:

* **Packages removed from PyPI.** `aiida-wannier90` and
  `aiida-wannier90-workflows` both 404 now; pinned versions only resolve from
  GitHub tags. Six projects pin them, hence
  [`overrides.txt`](overrides.txt). An override on a top-level pin does not
  reach a *transitive* requirement, so the replacement specs are passed as
  `--override`, which applies at any depth.
* **Environments that were already internally inconsistent.** One project
  required `aiida-quantumespresso>=4.9,<5` while its checkout was 4.6.0. pip
  installs in order and merely warns; `uv` backtracks and refuses. Nothing ever
  satisfied both. `NO_DEPS=1` installs the freeze verbatim without resolution,
  which reproduces what was actually there, conflict included.
* **A source-only dependency that had always compiled silently.**
  `BoltzTraP2` has no wheels on PyPI and failed with `No such file or
  directory: 'cmake'`, because `cmake` was present before the upgrade and not
  after.

### Netplan's `gateway4`

`gateway4:` is deprecated and **no longer honoured by the netplan in 24.04**,
which expects `routes:`. It did not matter before the upgrade, because the DHCP
file supplied a default route too, but afterwards the static file would have
silently stopped contributing one, leaving reachability dependent on DHCP alone.
With no console, that is not a dependency worth accepting.

`routes:` works identically on 22.04, so the change is safe to make *before*
upgrading. Deleting the DHCP file instead is the worst option: it removes the
fallback while leaving the deprecated keyword, so 24.04 would have no default
route at all.

Change it with two terminals open plus your workstation, and use `netplan try`.
The terminal running it is the one that may go silent.

### Reading rsync's progress honestly

`--info=progress2` reports a **byte-weighted** percentage. It sat at 99% for
hours while ~1.55M small `.cif`/`.in`/`.out` files remained, because those weigh
almost nothing. `ir-chk=N/M` is per-segment and its denominator grows as
incremental recursion discovers directories, so a small `N` does not mean nearly
finished. The honest signal is `xfr#` against the denominator.

### Other things learned the hard way

* **`/nfs` is autofs, not a static mount.** It will not appear in `df` until
  something touches it.
* **`/tmp` is cleared on boot**, and this box gets rebooted repeatedly during an
  upgrade. Staging scripts there loses them. `post-reboot.sh` was lost this way
  before it was ever run.
* **`verdi storage integrity` is a stub with an empty body** and does nothing.
  The real check is disk-objectstore's own CLI: `dostore -p <container>
  validate`.
* **The container is only half of a `psql_dos` profile.** A backup that covers
  the container but not the database covers nothing recoverable, which is why
  `aiida-backup.sh` does both together.
* **One profile had its database and repository split across filesystems**, and
  that is intended rather than a mistake. Check
  [`../profiles/repository-map.md`](../profiles/repository-map.md) before
  assuming where a profile's data lives.

## Sequence

The numbered sequence, with the script for each step, is in
[`../README.md`](../README.md).

Two framing points for planning it:

* **Request console access first.** The 2026 upgrade was completed without one,
  which was luck rather than judgement. `do-release-upgrade` starts a fallback
  `sshd` on port 1022 for the duration, with a different host key, so add a
  separate `~/.ssh/config` entry for it in advance and verify you can reach it
  *before* you need it.
* **Keep the collection step's output.** `weekend-prep.sh` captures a `pip
  freeze` per venv, an `/etc` tarball, package state and the PostgreSQL globals.
  That freeze set is the only way to reconstruct an environment afterwards, and
  it is what made rebuilding 20 of them on their original pins possible.
