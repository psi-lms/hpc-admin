# thanos follow-ups after the 24.04 upgrade

Everything found during the upgrade that is worth doing but was deliberately not done during it. Grouped by who has to decide.

## For the users, per project

### Disk cleanup, roughly 2 TB available

| what | size | note |
|---|---|---|
| `.aiida` archive exports | **1.5 TB in 649 files** | ~360 GB of same-named duplicates in the top 10 alone. Regenerable with `verdi archive create`. Duplicate paths recorded in `runlog.md` |
| `mc3d-source` calculation workdir | 13.2M files, 542 GB | ~855k calculation directories, each with `.in`, `.out`, `.aiida/`. If the calculations are in a profile, `verdi calcjob cleanworkdir` reclaims it. **This is what makes any `/home` backup take days**, not the bytes |
| `~/tmp` | 351 GB | |
| `mc3d-source/.aiida/daemon/log/aiida-dev.log` | **15 GB** | a single daemon log. Wants rotating, not backing up |
| `fermisurf/data/aiida-fermisurf.psql` | 13 GB | stray database dump, superseded by the real per-profile backups |
| `.upf`/`.UPF` pseudopotentials | 45 GB in 40k files | scattered per-calculation copies of redownloadable files |
| `~/.vscode-server` | 10.8 GB | |

### Profiles that could go

Confirmed disposable with the main user on 2026-08-20, still present:

- `kristjan_tests/sssp-sqlite` (88 GB)
- `sirius_tests/presto` (3.7 GB), `sirius_tests/qe_tests` (710 MB)

Empty profiles cluttering the list (36 KB containers, ~9 MB databases): `hubml/hubml-dev`, `hubml/hubml-prod`, `pseudo-opt/dev`, `pseudo-opt/prod`, `mc3d-spin_orbit/prod`, `kristjan_tests/mc3d-pbesol-v2`, `kristjan_tests/presto`, `mc3d-source/source-test`, `thor-dev/thor-dev`.

Also `mc3d-relax/prod` and `mc3d-relax/prod-zmq` share one database **and** one repository. Understand which is real before either is touched.

### Package and Python upgrades

**Not optional:** six projects are on **`aiida-core==2.7.1`, which is yanked** for "shell injection possible when using with OpenSSH < 9.0 as transport backend". Any profile submitting to a cluster running SSH older than 9.0 is exposed. Affects `ali-playground`, `hubml`, `mc3d-super`, `pseudo-opt`, `sirius_tests`, `sssp_tutorial`. Fix is 2.7.3 or later.

**Worth doing for active projects:** 19 of 20 venvs are on Python 3.10, which is security-only and EOL in October 2026. They were rebuilt on 3.10 deliberately, to change one thing at a time during the migration. `uv` makes moving per-project cheap and reversible:

```bash
uv python install 3.12
uv venv --python 3.12 ~/.aiida_venvs/<project>
```

Two things that will surface when anyone tries:

- **`aiida-wannier90` and `aiida-wannier90-workflows` have been removed from PyPI.** Both 404 now; the pinned versions only resolve from GitHub tags. Six projects pin them. See `overrides.txt`.
- **`mc3d-electronic` has an unsatisfiable constraint**: `aiidalab-qe==25.3.0` requires `aiida-quantumespresso>=4.9,<5` but its checkout is 4.6.0. pip tolerated this and merely warned; uv refuses. It was rebuilt with `--no-deps` to reproduce what was actually there. Someone should decide which of the two moves.

### Housekeeping once verified

- `~/.aiida_venvs/*.pre-noble`, the 20 preserved pre-upgrade environments. Keep until each project's owner confirms, then delete.
- `first-hero-run-backup-2024` at `/nfs/nfsbackup/aiida_thanos/`: 487 GB (measured 2026-09-02), untouched since 18 July 2024, on no schedule.
- The `aiida-prod_1` database: 8.9 MB, referenced by no profile.

## Artefacts this upgrade created, and when to delete them

Roughly **3.4 TB** reclaimable once things are confirmed working. Nothing here should go before users have reported back.

| what | where | size | when |
|---|---|---|---|
| ~~**PostgreSQL 14 cluster**~~ | `/home/postgres/postgresql/14/main` | **1.5 TB** | **dropped 2026-10-01** with `sudo pg_dropcluster 14 main`. PG 16 held 1485 GB across 36 databases against the 14 directory's 1.5 TB, so bytes and database count both matched before the drop. The remaining rollback from the 16 migration is the 34 GB `pg_dumpall` on NFS |
| **`/home/aiida` rsync copy** | `_home-aiida/20260821-152301/` on NFS | **1.84 TB, 12.9M files** | mostly redundant: 1.5 TB of it is the archive exports users are being asked to delete anyway. Better to delete it and re-take a much smaller copy after their cleanup than to keep this one |
| **full `pg_dumpall`** | `_pg-dumpall/pgdumpall-20260824-112454.sql.gz` | 34 GB | redundant with the per-profile `db.psql` files, which cover all 36 profiles. Keep until the 14 cluster goes, then it is the belt to that braces |
| **pre-upgrade venvs** | `~/.aiida_venvs/*.pre-noble` (20 of them) | ~12 GB | once each project's owner confirms their environment works. They are the only way to diff a missing package |
| `first-hero-run-backup-2024` | `/nfs/nfsbackup/aiida_thanos/`, not created by us | 487 GB | untouched since 18 July 2024, on no backup schedule. Ask whose it is |

Small and worth keeping as the record of what was done: `~/monday-prep-20260824-111737/` (the `pip freeze` set, `/etc` tarball, package state), `~/venv-rebuild-logs/`, `~/storage-info-*/`, `~/backup-run-20260820-134737/`, the crontab copies in `~`, and `/var/backups/{netplan-2026-08-24,etc-postgresql-14-*.tgz}`.

**Two that need action rather than deletion:**

- `_system-config/` on NFS contains the `pip freeze` files, **including the leaked GitHub token**. Scrub or delete it when the token is revoked.
- `/home/aiida/project/mc3d-electronic/git-repos/mc3d-source/LICENSE.txt` is an untracked file created during the rebuild, because that checkout's `pyproject.toml` names `LICENSE.txt` while the tracked file is `LICENSE`. Leave it, or update the checkout to a commit where upstream fixed it. Worth recording so nobody later wonders where it came from.

Also note the manual backup run used `--keep 6` while cron uses 3, so a few extra generations exist on NFS and will prune themselves over the next few nights.

## For JG

- **Revoke the leaked GitHub token.** A `ghp_` classic PAT is embedded in a `pip freeze` line for `Minotakm/hith.git`. Scrubbing the files does not invalidate it; only revoking at `github.com/settings/tokens` does. It has been in terminal scrollback and in a backup on NFS.
- ~~**`pg_dropcluster 14 main`**~~ **done 2026-10-01.** Together with the 790 GB of Flaviano export archives under `/home/aiida/exports`, `/home` went from 90% to **80%** (19 T of 25 T, 4.7 T free).
- [x] ~~Unmask the automatic-update units.~~ Done 2026-08-25; all three enabled and the first `apt upgrade` since has run cleanly.
- [x] ~~Restore the backup crontab.~~ Done 2026-09-09: 19 entries, 36 profiles, 00:00 to 04:30, preflight clean. Backups had been suspended since 2026-08-24, so 16 days with none. Reversal copy at `~/crontab.before-restore-20260909-175055.txt`. **Still to check: the first run on 2026-09-10.**
- **`shared_buffers` is still 128 MB**, the packaged default, carried over into PostgreSQL 16 on a 251 GB machine.
- **Re-enable deadsnakes for noble** if `mc3d-relax` is to keep Python 3.13: change `jammy` to `noble` in `/etc/apt/sources.list.d/deadsnakes-ubuntu-ppa-jammy.list`.
- **Consolidate the netplan config** on a quiet day: one file instead of two, which clears the duplicate address and the permanently failing `systemd-networkd-wait-online.service`.

## For the team, to decide

- **Whether to keep copying the `/nfs/aiida_data` repositories to `/thanosbackup`**, pending Michel's answer on how `/aiida_data` is protected. If SnapMirror replicates it to separate hardware with useful retention, the container copy is redundant and worth ~0.9 TB plus the nightly transfer. Two things make it more than deleting a crontab line: the four profiles keep their databases in PostgreSQL on `/home` (`database_hostname: localhost`), which `/aiida_data` does not cover, and `aiida-backup.sh` backs up a profile as `container` plus `db.psql` together, so skipping the container needs a script change rather than a config one.


- **microk8s.** Confirmed to run nothing but its own plumbing (calico, coredns), with pods stuck `Terminating` for over two years and one `Pending` for 509 days. It is v1.28, past upstream support. Does it stay?
- **The shared `aiida` account's default SSH key authenticates to GitHub as `npaulish`.** One person's identity acting for everyone, and adjacent to the leaked-token problem.

## Backup system, worth fixing properly

- **Derive the profile list from `verdi profile list`** instead of hardcoding it. `aiida-backup.sh` already does this when `-p` is omitted. The crontab pinning one profile per line is why 28 of 41 profiles were unprotected until 2026-08-20, and why nothing warns when a new profile appears.
- **`aiida-backup-checker.py` reports a crash as absence.** It only matches `Success`/`Failure`, so a traceback removes the project from the table entirely rather than flagging it red. This is exactly how `fermisurf` went unnoticed. It should assert one row per expected profile.
- **`verdi storage backup` runs maintenance, which fails on a profile being written to.** Any profile busy at its cron slot can fail this way. Either stop daemons around the backup window or accept periodic failures, but the checker must make them visible.
- **Commit the crontab into the `aiida-backup-script` repo.** It is now the only description of what gets backed up, and nothing versions it.

## For PSI central computing

- **Console access.** `192.168.8.x` is unreachable from every host JG can use, and the gateways the lab wiki documents no longer resolve. The upgrade was completed without a console; the next one should not have to be. A request was drafted but not carried into this repository.
- **The filer, and what it already protects.** Mail **sent 2026-09-15** to Michel Rebman, Cc Bud, Giovanni, Ali and Nataliya, asking how `/aiida_data` is protected and for how long at the SnapMirror destination, and whether the two volumes share physical disks; plus Bud's quota request for `mpc2976`. Full text is gone from disk, but the questions are recorded in [`runlog-2026-08.md`](runlog-2026-08.md). **Awaiting reply.** What is known from the client, checked 2026-09-02:

| | `/nfs/aiida_data` | `/nfs/nfsbackup` (`thanosbackup`) |
|---|---|---|
| size | 17 TB, 69% used | 29 TB, 82% used |
| snapshots | **132**: 24 x 10min (4 h), 72 x hourly (3 d), 31 x daily (30 d), 4 x weekly | **none** |
| SnapMirror | yes, `snapmirror.e62e2629-...` refreshed daily | no sign of one |

  Both are volumes on one NetApp SVM, `svmnfs.psi.ch` = `129.129.160.237`, which serves 58 exports across PSI. So the volume holding every AiiDA backup is the one with no snapshot protection, and it shares a filer with the live data it protects. Open questions: same aggregate and disks? Where does SnapMirror land, and with what retention? Are the export policies host-restricted, given both show as `(everyone)`?

- **Who can delete `paulis_n` (~11 TB), answered 2026-09-09.** It is group-writable to `unx-msd` (gid 204842), 17 members: `baingl_e bercx_m eimre_k paulis_n goscin_a khosra_a macaul_b zadoks_a bonacc_m pizzi_g wang_x3 minota_m geiger_j reents_t tettam_p granat_v muuga_k`. Resolvable from `lms-login.psi.ch` but not from thanos, which has no PSI directory. Not confined to thanos either: lms-login automounts `/nfs/aiida_data` read-write (`x-systemd.automount`, 5 min idle), so the volume root is unwritable there (owned by thanos's uid 1001) while `paulis_n` below it is writable by all 17. That is why GP reported he could not write "in there" from lms-login: he was at the volume root.

- **Snapshots are the recovery path nobody in the group knew about.** `.snapshot` exists inside every directory, is read-only to all NFS clients including root, and survives deletion of the directory it appeared in (the live tree goes, the snapshot copy under any surviving ancestor stays). Roughly 30 days of coverage on `aiida_data`. Raised on the "aiida_data is not backed up" thread, where the proposal on the table was to buy a second NFS and run an rsync hard-link rotation, which would be writable and therefore deletable by the same mistake it protects against.

## Upstream, drafted in `aiida-core/.github/`

- `issue-storage-backup-consistency-check-race.md`: `verdi storage backup` aborts on an active profile because its maintenance step runs a consistency check, and the failure is invisible to log-scraping monitors.
- `issue-maintain-full-defeats-backup-hardlinks.md`: `verdi storage maintain --full` repacks the container, so the next `verdi storage backup` re-transfers everything, with nothing documenting the interaction.

Also worth reporting, found today: **running `verdi` from a newer aiida-core silently migrates a profile's `config.json`** to a newer schema, after which the intended version refuses to read it. No prompt, no warning. It cost us `mc3d-electronic` briefly when a failed rebuild left 2.9.0 installed.
