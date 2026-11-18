# Follow-ups after the 24.04 upgrade

Everything found during the August 2026 upgrade that is worth doing but was
deliberately not done during it. Grouped by who has to decide. Still open as of
2026-11-18 unless marked.

A handful of items are held back from this public repository because they
describe unfixed weaknesses or name individuals; they live in the maintainer's
notes. Ask before assuming this list is complete.

## For the users, per project

### Disk cleanup

**No owner feedback ever arrived on any of this, so nothing has been deleted.**
Sizes measured 2026-09-02 unless noted.

* **1.5 TB in 649 files**, `.aiida` archive exports under `project/*/`. ~360 GB
  of same-named duplicates in the top 10 alone. Regenerable with `verdi archive
  create`.
* **542 GB in 13.2M files**, `mc3d-source` calculation workdir. ~855k
  calculation directories, each with `.in`, `.out`, `.aiida/`. If the
  calculations are in a profile, `verdi calcjob cleanworkdir` reclaims it.
  **This file count, not its size, is what makes any `/home` backup take days.**
* **351 GB**, `~/tmp`.
* **75 GB in 3.73M files**, `mc3d-source/scripts/cif-export`. Regenerable.
* **45 GB in 40k files**, `.upf`/`.UPF` pseudopotentials scattered as
  per-calculation copies of redownloadable files.
* **15 GB**, `mc3d-source/.aiida/daemon/log/aiida-dev.log`. A single daemon log.
  Wants rotating, not backing up.
* **13 GB**, `fermisurf/data/aiida-fermisurf.psql`. A stray database dump,
  superseded by the real per-profile backups.
* **10.8 GB**, `~/.vscode-server`.
* **487 GB**, `first-hero-run-backup-2024` on the backup volume. Not created by
  this work, untouched since 18 July 2024, on no backup schedule. Ask whose it
  is.

Reclaimed since: the PostgreSQL 14 cluster (1.5 TB, dropped 2026-10-01) and the
pre-upgrade `/home/aiida` copy (1.84 TB, deleted 2026-11-18). `/home` went from
90% to 81%.

### Profiles that could go

Confirmed disposable with the main user on 2026-08-20, still present:
`kristjan_tests/sssp-sqlite` (88 GB), `sirius_tests/presto` (3.7 GB),
`sirius_tests/qe_tests` (710 MB).

Empty profiles cluttering the list (36 KB containers, ~9 MB databases):
`hubml/hubml-dev`, `hubml/hubml-prod`, `pseudo-opt/dev`, `pseudo-opt/prod`,
`mc3d-spin_orbit/prod`, `kristjan_tests/mc3d-pbesol-v2`,
`kristjan_tests/presto`, `mc3d-source/source-test`, `thor-dev/thor-dev`.

`mc3d-relax/prod` and `mc3d-relax/prod-zmq` share one database **and** one
repository. Understand which is real before either is touched.

### Package and Python upgrades

**Not optional:** six projects are on **`aiida-core==2.7.1`, which is yanked**
for "shell injection possible when using with OpenSSH < 9.0 as transport
backend". Any profile submitting to a cluster running SSH older than 9.0 is
exposed. Affects `ali-playground`, `hubml`, `mc3d-super`, `pseudo-opt`,
`sirius_tests`, `sssp_tutorial`. The fix is 2.7.3 or later.

**Worth doing for active projects:** 19 of 20 venvs are on Python 3.10, which is
security-only and EOL in October 2026. They were rebuilt on 3.10 deliberately,
to change one thing at a time during the migration. `uv` makes moving
per-project cheap and reversible:

```bash
uv python install 3.12
uv venv --python 3.12 ~/.aiida_venvs/<project>
```

Two things will surface when anyone tries: the two `aiida-wannier90` packages
removed from PyPI, and one project's unsatisfiable `aiidalab-qe` constraint.
Both are covered in [`README.md`](README.md) and
[`overrides.txt`](overrides.txt).

### Housekeeping once verified

* `~/.aiida_venvs/*.pre-noble`, the 20 preserved pre-upgrade environments,
  ~12 GB. Keep until each project's owner confirms theirs works; they are the
  only way to diff a missing package.
* The `aiida-prod_1` database: 8.9 MB, referenced by no profile.
* One checkout has an untracked `LICENSE.txt` created during the rebuild,
  because that commit's `pyproject.toml` names `LICENSE.txt` while the tracked
  file is `LICENSE`. Upstream fixed it in a later commit. Leave it, or update
  the checkout, but record it so nobody later wonders where it came from.

## Outstanding for the maintainer

* **`shared_buffers` is still 128 MB**, the packaged default, carried into
  PostgreSQL 16 on a 251 GB machine.
* **Re-enable deadsnakes for noble** if `mc3d-relax` is to keep Python 3.13:
  change `jammy` to `noble` in the deadsnakes sources list.
* **Consolidate the netplan config** on a quiet day: one file instead of two,
  which clears the duplicate address and the permanently failing
  `systemd-networkd-wait-online.service`.
* [x] ~~Unmask the automatic-update units.~~ Done 2026-08-25; all three enabled
  and every `apt upgrade` since has run cleanly.
* [x] ~~Restore the backup crontab.~~ Done 2026-09-09: 19 entries, 36 profiles,
  00:00 to 04:30, preflight clean. Backups had been suspended since 2026-08-24,
  so 16 days with none.

## For the team, to decide

* **Whether to keep copying the `/nfs/aiida_data` repositories to the backup
  volume**, pending an answer on how that volume is already protected. If
  replication covers it to separate hardware with useful retention, the
  container copy is redundant and worth ~0.9 TB plus the nightly transfer. Two
  things make it more than deleting a crontab line: the four profiles keep their
  databases in PostgreSQL on `/home`, which the data volume does not cover, and
  `aiida-backup.sh` backs up a profile as container plus `db.psql` together, so
  skipping the container needs a script change rather than a config one.
* **microk8s.** Confirmed to run nothing but its own plumbing (calico, coredns),
  with pods stuck `Terminating` for over two years and one `Pending` for 509
  days. It is v1.28, past upstream support. Does it stay?

## For PSI central computing

* **Console access.** The management subnet is unreachable from every host the
  maintainer can use, and the gateways the lab wiki documents no longer resolve.
  The upgrade was completed without a console; the next one should not have to
  be.
* **The filer, and what it already protects.** Mail sent 2026-09-15, **no reply
  as of 2026-11-18**, asking how the live data volume is protected, for how long
  at the replication destination, and whether the two volumes share physical
  disks. What is known from the client, checked 2026-09-02:

  | | live data volume | backup volume |
  |---|---|---|
  | size | 17 TB, 69% used | 29 TB, 82% used |
  | snapshots | **132**: 24 x 10min (4 h), 72 x hourly (3 d), 31 x daily (30 d), 4 x weekly | **none** |
  | replication | yes, refreshed daily | no sign of any |

  Both are volumes on one NetApp SVM serving 58 exports across the site. So the
  volume holding every AiiDA backup is the one with no snapshot protection, and
  it shares a filer with the live data it protects.

* **Snapshots are the recovery path nobody in the group knew about.**
  `.snapshot` exists inside every directory on the live data volume, is
  read-only to all NFS clients including root, and survives deletion of the
  directory it appeared in. Roughly 30 days of coverage. Worth knowing before
  anyone proposes buying a second NFS and running an rsync hard-link rotation,
  which would be writable and therefore deletable by the same mistake it
  protects against.

## Backup system, worth fixing properly

* **Derive the profile list from `verdi profile list`** instead of hardcoding
  it. `aiida-backup.sh` already does this when `-p` is omitted. The crontab
  pinning one profile per line is why 28 of 41 profiles were unprotected until
  2026-08-20, and why nothing warns when a new profile appears.
* **`aiida-backup-checker.py` reports a crash as absence.** It only matches
  `Success`/`Failure`, so a traceback removes the project from the table
  entirely rather than flagging it red. This is exactly how one profile went
  unnoticed. It should assert one row per expected profile.
* **`verdi storage backup` runs maintenance, which fails on a profile being
  written to.** Any profile busy at its cron slot can fail this way. Either stop
  daemons around the backup window or accept periodic failures, but the checker
  must make them visible.
* **Commit the crontab into the `aiida-backup-script` repo.** It is now the only
  description of what gets backed up, and nothing versions it.
  [`../backups/crontab.txt`](../backups/crontab.txt) here is a snapshot, not the
  live state.

## Reported upstream

* `verdi storage backup` aborts on an active profile because its maintenance
  step runs a consistency check, and the failure is invisible to log-scraping
  monitors.
* `verdi storage maintain --full` repacks the container, so the next `verdi
  storage backup` re-transfers everything, with nothing documenting the
  interaction.
* Running `verdi` from a newer aiida-core silently migrates a profile's
  `config.json` to a newer schema, after which the intended version refuses to
  read it. No prompt, no warning.
