# Exporting a large group as an archive

Worked example from September 2026: handing an external collaborator a subset of
the `workchain/PBEsol/bands/lumi` group as an AiiDA archive, so they can run
their own QueryBuilder queries without an account on thanos. 10,000 workchains
out of 33,191.

Kept because the sizes, timings and pitfalls are the reusable part. The
collaborator and group owner are referred to by role.

## What the data is

| | |
|---|---|
| project | `mc3d-pbesol-v1`, `/home/aiida/project/mc3d-pbesol-v1` |
| profile | `prod`, db `mc3d-pbesol-v1-prod`, repo `file:///nfs/aiida_data/repositories/mc3d-pbesol-v1/prod` |
| venv | `/home/aiida/.aiida_venvs/mc3d-pbesol-v1` (sourcing it also sets `AIIDA_PATH`) |
| source group | `workchain/PBEsol/bands/lumi`, pk 14, uuid `219b7062-6186-4f15-998d-01c02f9e4328`, owned by the group owner |
| contents | 33191 `PwBandsWorkChain`, 31252 with `exit_status = 0`, one per input structure |
| export group | `workchain/PBEsol/bands/lumi/export/flaviano-10k`, uuid `48579708-809f-4be6-93db-0f9660e86304`, 10000 workchains |

A second, near-empty `workchain/PBEsol/bands/lumi` (1 node) exists in
`fermisurf/main`. Address the group by uuid, not label.

The export group was built by [`make-export-group.py`](make-export-group.py),
which runs the collaborator's own query including
the `scf` -> `iteration_01` joins, so every workchain in it yields a row for him.
`verdi group delete` removes it; it is the only write this whole exercise makes
to the production profile.

## Measured sizes

Per workchain, from the disk-objectstore index:

| component | per workchain | for 10000 |
|---|---|---|
| node rows in the database | ~39 kB | ~390 MB |
| `retrieved` folders of the CALL-closure calcjobs | ~5.7 MB | ~57 GB (see the correction below: the real total is ~295 GB) |
| all `BandsData` `.npy` arrays | 1.82 MB | ~18 GB |
| scf `output_band` only | 0.21 MB | ~2.1 GB |

The whole `prod` repository is 4.88 TB across 12,471,477 objects, mean 382 kB;
the database is 28 GB over 14.3M nodes and 33.8M links.

## State overnight, 2026-09-16 21:09 UTC

Two exports were started, in a tmux session on the workstation with the ssh to
thanos inside it. Only one of them had `TMPDIR` set, which is the whole story
below.

**The one that matters for Tuesday**, pid 2414365, started 20:56:

```bash
verdi -p prod archive create --compress 0 --exclude-logs --exclude-comments \
    -G 48579708-809f-4be6-93db-0f9660e86304 -- /home/aiida/exports/lumi-10k.aiida
```

Traversal took ~9 minutes, then it began writing. Measured growth **3.6 MB/s**
(842 MB at 21:09) during the database phase, which finished by 21:25; it is now
copying 941,758 repository objects. At ~295 GB the file phase is the long pole
and the finish time depends on how fast the packs stream off NFS (observed
~930 MB/s of reads early on). `--compress 0` is deliberate: almost all of that archive is
discarded in the repackage below, so deflating it would cost hours for bytes
nobody keeps. The shareable file is compressed on the way out instead.

**The full group**, pid 2429519, started 21:05, **killed**: it had no `TMPDIR`
set, so it was writing `/tmp/tmpoju5gpzf/export.zip` and
`/tmp/tmpsp7_z6ke/db.sqlite3` on `/dev/sdb2`, the root filesystem, with 184 GB
free against a ~1 TB archive. It would have filled `/`.

```bash
verdi -p prod archive create -G 219b7062-6186-4f15-998d-01c02f9e4328 \
    -- /home/aiida/exports/bands-pbesol-lumi.aiida
```

`export TMPDIR=/home/aiida/exports/tmp` has to be set **in the same shell** as
the command. It is not inherited from another pane or another ssh session.

It also lacked `--compress 0` and the excludes, so it would have deflated the
whole thing at level 6 and carried 1,064,427 logs.

### Real entity counts, from the runs themselves

| | nodes | logs | links | share of profile nodes |
|---|---|---|---|---|
| 10000 workchains | 864,443 | excluded | 2,090,260 | 6.0% |
| full group | 2,907,453 | 1,064,427 | 7,015,560 | 20.3% |

The container holds 12,471,477 objects in 4.88 TB, mean 382 kB. Scaling by node
share puts the 10k export at **~295 GB** of repository content (941,758 objects,
as its own progress bar reports) and the full group at **~990 GB**.

An earlier estimate in this file of 57 GB for the 10k was wrong by ~5x. It
extrapolated the `retrieved` folders of the CALL-closure calcjobs only;
`create_backward` walks upstream from every input structure and drags in a whole
second population of file-bearing nodes. Trust the archive's own
"Creating archive with:" table, not extrapolation.

Disk on `/home` is not a concern at 4.5 TB free, and because `TMPDIR` is on the
same filesystem the final `shutil.move` is a rename rather than a copy.

### Outcome, 2026-09-17

Both finished successfully overnight.

One directory per group, named after the group label with the slashes turned into
hyphens. Filenames name the profile and the slice, so they still describe
themselves once downloaded and the directory context is gone.

```
/home/aiida/exports/
├── workchain-PBEsol-bands-lumi/
│   ├── mc3d-pbesol-v1-bands-lumi-full.aiida        652 GB   provenance + repository
│   └── mc3d-pbesol-v1-bands-lumi-db.aiida          1.98 GB
├── workchain-PBEsol-bands-lumi-export-flaviano-10k/
│   ├── mc3d-pbesol-v1-bands-lumi-10k-full.aiida    193 GB
│   └── mc3d-pbesol-v1-bands-lumi-10k-db.aiida      486 MB   <- the one for the collaborator
└── tmp/                                                     TMPDIR, keep
```

| file | bytes | entries | `db.sqlite3` inside | repackaged to |
|---|---|---|---|---|
| `mc3d-pbesol-v1-bands-lumi-10k-full.aiida` | 192,839,081,772 (180 GiB), 00:06 | 941,760 | 1,682,731,008 (1.68 GB) | 485,723,354 (486 MB) |
| `mc3d-pbesol-v1-bands-lumi-full.aiida` | 651,983,590,798 (607 GiB), 05:05 | 3,164,702 | 7,921,844,224 (7.92 GB) | 1,976,738,950 (1.98 GB) |

941,760 entries is exactly the 941,758 objects the progress bar reported plus
`metadata.json` and `db.sqlite3`, so nothing was dropped. Both archives carry
those two as their first two members, which is what `search_limit=4` needs.

The ~295 GB and ~990 GB projections above were both high by a factor of ~0.65:
the container's 382 kB mean object size is inflated by other groups' large files,
while this subtree averages ~233 kB. The shareable file also came out larger than
the 150-250 MB predicted below, because `db.sqlite3` is 1.68 GB rather than the
~390 MB of raw node rows: 486 MB after `zip -6`, a 3.5x ratio.

### First thing tomorrow

1. `ls -la /home/aiida/exports/` — is `lumi-10k.aiida` there (temp dir gone, file
   present, expect ~295 GB)? If yes, the repackage below is all that is left.
2. If it is still running: `du -sb /home/aiida/exports/tmp/tmp*` twice a minute
   apart gives the current rate and therefore the ETA.
3. The full-group job was killed (see above). If you restart it, set `TMPDIR` in
   that shell first, add `--compress 0 --exclude-logs --exclude-comments`, and
   expect ~990 GB. Check `df -h /` for leftovers under `/tmp` either way.

## Tomorrow

Strip the archive to database only. Keep the argument order: the sqlite_zip
reader looks for these members in the first 4 records of the zip
(`search_limit=4`), so they must come first.

```bash
cd /home/aiida/exports
mkdir -p slim
cd slim
unzip -o ../lumi-10k.aiida metadata.json db.sqlite3
zip -X -6 ../lumi-10k-db.aiida metadata.json db.sqlite3
ls -lh ../lumi-10k-db.aiida
```

Expect roughly 150-250 MB. Then confirm it answers his query, with only the
group label changed from the original:

```bash
source /home/aiida/.aiida_venvs/mc3d-pbesol-v1/bin/activate
python -c "
from aiida import load_profile, orm
from aiida.storage.sqlite_zip.backend import SqliteZipBackend
load_profile(SqliteZipBackend.create_profile('/home/aiida/exports/lumi-10k-db.aiida'), allow_switch=True)
qb = orm.QueryBuilder()
qb.append(orm.Group, filters={'label': 'workchain/PBEsol/bands/lumi/export/flaviano-10k'}, tag='group')
qb.append(orm.WorkChainNode, tag='PwBandsWorkChain', with_group='group', project='*', filters={'attributes.process_label': 'PwBandsWorkChain', 'attributes.exit_status': 0})
qb.append(orm.WorkChainNode, tag='PwBaseWorkChainSCF', with_incoming='PwBandsWorkChain', edge_filters={'label': 'scf'})
qb.append(orm.CalcJobNode, tag='Calcjob', with_incoming='PwBaseWorkChainSCF', project='*', edge_filters={'label': 'iteration_01'}, filters={'attributes.exit_status': 0})
print('rows:', qb.count())
"
```

A repo-less archive loads fine: for a zip path the backend constructs
`ZipfileBackendRepository` unconditionally and resolves objects lazily by member
name, so nothing validates the repository until a file is actually read
(`aiida/storage/sqlite_zip/backend.py:243-249`). It would *not* survive
`verdi archive import`, which needs the objects.

### Archive format version

thanos runs aiida-core 2.7.3, which writes `main_0001`. That is still the archive
head in every released aiida-core through v2.9.2: `main_0002` and `main_0003`
were added in [#7621](https://github.com/aiidateam/aiida-core/pull/7621), which is
on `main` and in no tag. So released versions read it directly, and only an
unreleased build (the local 2.10.0.dev0 checkout) needs migrating, because
`SqliteZipBackend.initialise` calls `validate_storage`:

```bash
verdi archive migrate lumi-10k-db.aiida lumi-10k-db-main0003.aiida
```

Verification therefore runs in the local `thanos-export` project
(`/home/geiger_j/aiida_projects/thanos-export`, aiida-core 2.8.0), which loads the
archive as written. Migrating on thanos is not an option anyway: 2.7.3 does not
know the later versions.

### Verifying the result

`verify-query.py` loads an archive as a `sqlite_zip` profile, discovers
the group label from the archive, runs his query verbatim and probes one row to
show which parts survive without `repo/` members. `SqliteZipBackend.create_profile`
builds the `Profile` in memory and `load_profile(..., allow_switch=True)` never
touches `config.json`, so this registers nothing, but it is still better run on
the workstation than on thanos, since that is what the collaborator will actually do.

```bash
cd /home/geiger_j/aiida_projects/aiida-dev/git-repos/aiida-core
source .venv/bin/activate.fish
python verify-query.py ~/exports/lumi-10k-db-main0003.aiida
```

## Resolved: he needs the band arrays

He said "only the SQL db are enough, I don't search the files", then "I also need
the bands on a grid from the scf calculations". Those contradict: `BandsData`
keeps its eigenvalues as `.npy` in the node repository, so band energies are
files too. He was thinking of `aiida.out`/XML. `output_parameters` (fermi energy,
smearing, occupations) are database attributes and survive a database-only
archive; eigenvalues do not, confirmed by running his query against the 486 MB
file and getting `NOT AVAILABLE (FileNotFoundError)` for both band outputs.

Settled by shipping database plus every `BandsData` object and nothing else,
built with `build-bands-archive.py` from the already-created full archives. No
re-export, no traversal: it copies `metadata.json` and `db.sqlite3` verbatim and
the `repo/<sha256>` members named in the `repository_metadata` of `BandsData`
nodes. Verified against his query:

```
group discovered in archive: 'workchain/PBEsol/bands/lumi/export/flaviano-10k'
Total number of entries: 10000  (0.3s)
  output_parameters (database): 89 keys, {'fermi_energy': 5.3346, 'number_of_bands': 35, ...}
  scf grid bands (repository): (2, 201, 35)
  band structure (repository): (2, 206, 171)
```

| archive | contents | size |
|---|---|---|
| `HACK-NO-FILE-REPO-…-bands-lumi-10k.aiida` | database only, 10k materials | 486 MB |
| `HACK-BAND-NPY-ONLY-…-bands-lumi-10k.aiida` | **+ 43,489 BandsData / 130,291 objects** | **8.39 GB** |
| `HACK-NO-FILE-REPO-…-bands-lumi.aiida` | database only, all 31,252 | 1.98 GB |
| `HACK-BAND-NPY-ONLY-…-bands-lumi.aiida` | + 148,252 BandsData / 423,887 objects | 26.15 GB |
| `mc3d-pbesol-v1-bands-lumi-10k-full.aiida` | complete | 180 GiB |
| `mc3d-pbesol-v1-bands-lumi-full.aiida` | complete | 607 GiB |

The prefix states what the repository holds: `HACK-NO-FILE-REPO-` for none at
all, `HACK-BAND-NPY-ONLY-` for the `BandsData` `.npy` files and nothing else. The
two `-full.aiida` files are unmodified `verdi archive create` output and keep
plain names. Send under a hardlink with a clean name, since the prefixes are
internal warnings rather than something a recipient should see.

Do not tar before sending: a `.aiida` is already a zip, `SqliteZipBackend` wants
the file itself, and re-compressing deflated members buys nothing.

`build-bands-archive.py` needs `force_zip64=True` when streaming members: the
full group's `db.sqlite3` is 7.92 GB and `zipfile` cannot infer that a streamed
member crosses the 4 GB ZIP64 boundary.

Draft asking him in the handover message (not carried into this repository). If he wants
the arrays, they can be added to the already-built `lumi-10k.aiida` without a
second export: select the `repo/<sha256>` members belonging to `BandsData` nodes
and copy those into the slim zip after `db.sqlite3`.

## The aiida patch this depends on

`verdi archive create` on the full 33191-node group was unusable: one traversal
query ran **5h20m at 100% CPU without finishing**. Cause is
`_create_smarter_in_clause`, which splits value lists above 500k and combines
them with `OR`, which defeats the semi-join rewrite and forces full scans of
`db_dbnode` (14.3M) and `db_dblink` (33.8M) once per traversal iteration.

Worked around on thanos by raising the threshold in place:

```
/home/aiida/.aiida_venvs/mc3d-pbesol-v1/lib/python3.10/site-packages/aiida/storage/psql_dos/orm/querybuilder/main.py:813
    batch_threshold = 50_000_000     # was 500_000
```

Same query afterwards: **under 20 seconds**. Note that the traversal is still not
instant on the full group, because the remaining time is Python-side set building
over ~1.4M nodes, not the database.

**This is a site-packages edit in the `mc3d-pbesol-v1` venv only.** Any reinstall
or upgrade of that venv silently reverts it, and the four other venvs carrying
the same code are untouched.

Upstream: [#7248](https://github.com/aiidateam/aiida-core/pull/7248) already has
the proper fix (`UNION ALL` instead of `OR`), open since 2026-03-02. Affects
v2.7.2 through v2.9.2. Drafts in the aiida-core checkout under `github/`:
`issue-in-clause-or-batching-defeats-index.md`, `pr-7248-body.md`,
`pr-7248-comment-benchmarks.md`.

Also relevant: [#6946](https://github.com/aiidateam/aiida-core/pull/6946), also
yours, also unmerged. `verdi archive create` writes the entire archive into
`tempfile.TemporaryDirectory()` and only `shutil.move`s it at the end
(`aiida/tools/archive/create.py:292,378`). `TMPDIR` is unset on thanos, so that
defaults to `/tmp` on `/dev/sdb2` with 184 GB free. Setting
`TMPDIR=/home/aiida/exports/tmp` is required for anything large, and also turns
the final move into a rename instead of a cross-filesystem copy.

## Sharing

Both at PSI, so a PSI share or SWITCHfilesender works. 150-250 MB is trivial to
send; the ~18 GB variant with all band arrays is not, and would want a share
rather than a transfer service.

## Cleanup when done

Delete `/home/aiida/exports/tmp`, `/home/aiida/exports/slim` and the ~295 GB
intermediate `/home/aiida/exports/lumi-10k.aiida`, then drop the export group:

```bash
verdi -p prod group delete workchain/PBEsol/bands/lumi/export/flaviano-10k
```

Keep `lumi-10k-db.aiida` until he confirms it works.
