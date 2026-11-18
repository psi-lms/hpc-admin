# thanos: every AiiDA profile, its repository, and whether it is backed up

Generated 2026-08-20 from every `project/*/.aiida/config.json`. 41 profiles across 22 projects. **13 are on the nightly backup cron.**

Three repository layouts are in use, which matters for any rsync exclude list:

1. `<project>/.aiida/repository/<profile>` (majority)
2. `<project>/repositories/<profile>` (fermisurf, mc3d-electronic/dev, mc3d-relax/prod+prod-zmq, mc3d-source/dev+prod+test, mc3d-super/prod)
3. `/nfs/aiida_data/repositories/<project>/<profile>` (alps_run x3, mc3d-pbesol-v1/prod)

## On the backup cron

| project | profile | container size |
|---|---|---|
| electrides_test | presto | 8.9G |
| fermisurf | main | (in `repositories/main`) |
| mc3d-electronic | dev | (in `repositories/dev`) |
| mc3d-electronic | test_2 | 6.9T |
| mc3d-relax | prod | (in `repositories/prod`) |
| mc3d-relax-so | presto | 1.4T |
| mc3d-source | dev | (in `repositories/dev`) |
| mc3d-source | prod | (in `repositories/prod`) |
| mc3d-spin_orbit | presto | 130G |
| sssp-project | full-24-07 | 574G |
| sssp-project | presto | 15G |
| sssp-tests | correct_cutoffs | 23G |
| sssp-tests | presto | 15G |

## Not on any backup cron

Ordered by how much it would hurt to lose.

| project | profile | backend | container | note |
|---|---|---|---|---|
| mc3d-super | prod | psql_dos | ~346G | layout 2 |
| mc3d-relax-mpds | prod | psql_dos | 257G | |
| kristjan_tests | sssp-sqlite | sqlite_dos | 88G | **disposable**, confirmed with the main thanos user 2026-08-20; not added to the cron |
| sssp-tests | precision_tests | psql_dos | 34G | |
| sssp-tests | final_sssp_tests | psql_dos | 16G | |
| sssp-tests | pbesol_tests | psql_dos | 3.2G | |
| sirius_tests | presto | psql_dos | 3.7G | **disposable**, confirmed 2026-08-20 |
| sssp_tutorial | presto | psql_dos | 1.6G | |
| mc3d-relax | dev | sqlite_dos | 1.3G | |
| sirius_tests | qe_tests | psql_dos | 710M | **disposable**, confirmed 2026-08-20 |
| ali-playground | dev | sqlite_dos | 211M | |
| mc3d-source | batio | sqlite_dos | 6.2M | |
| mc3d-source | test | psql_dos | layout 2 | |
| mc3d-spin_orbit | prod | psql_dos | 36K | empty |
| hubml | hubml-dev, hubml-prod | psql_dos | 36K each | empty |
| kristjan_tests | mc3d-pbesol-v2, presto | mixed | 36K each | empty |
| mc3d-source | source-test | sqlite_dos | 36K | empty |
| pseudo-opt | dev, prod | psql_dos | 36K each | empty |
| thor-dev | thor-dev | sqlite_dos | 76K | empty |

Roughly **1.6 TB of container data is not on any backup schedule**. Split it two ways:

- ~889 GB (`alps_run` x3, `mc3d-pbesol-v1/prod`) sat on `/nfs/aiida_data` with no second copy and no database dump. **Added to the crontab on 2026-08-20** at 04:15 and 04:30.
- ~700 GB (`mc3d-super/prod`, `mc3d-relax-mpds/prod`, the three extra `sssp-tests` profiles, `sssp_tutorial`, and the smaller ones) sits on `/home` with neither container nor database backed up. Covered by the replacement crontab in `crontab/`.
- `kristjan_tests/sssp-sqlite` (88G) and `sirius_tests/{presto,qe_tests}` (4.4G) are disposable, confirmed with the main thanos user on 2026-08-20, and stay off the schedule.

`verdi storage backup` also writes the `db.psql` dump, so an unbacked-up profile has no database dump either.

## Oddities worth a look

- `mc3d-relax/prod-zmq` shares both the database (`mc3d-relax-prod`) and the repository with `mc3d-relax/prod`. It is a duplicate profile entry with a different broker config, so `prod`'s backup covers it completely.
- `fermisurf/main` has `file:////home/...` (four slashes). It resolves. Its 2026-08-20 backup crashed with `RuntimeError: There are objects referenced in the database that are not present in the repository`, which is an integrity problem in the profile, not a backup problem.
- `alex_archive` and `workdir` have no `.aiida/config.json` at all: not AiiDA projects, just directories under `project/`.
