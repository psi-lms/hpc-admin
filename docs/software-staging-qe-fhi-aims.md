# Software staging: QE 7.5/7.6 and FHI-aims 261002

Staged by Austin Zadoks 2026-10-24, verified in place 2026-10-28.
NOT copied yet. Do QE and FHI-aims separately, see below.

## Source

`/scratch/zadoks_a/software/qe-build/software/` (14 GB + 172 MB):

| Staged directory | Size | Contents | Target |
|---|---|---|---|
| `qe/` | 14 GB | 7.5-gf, 7.6-gf, 7.5-ioapi, 7.6-ioapi, README.md, recipes-7.5-7.6/ | `/home/software/qe/` (exists) |
| `fhi-aims/` | 172 MB | 261002-gf, 261002-ioapi, README.md, recipes-261002/ | `/home/software/fhi-aims/` (does not exist yet) |

Recipe notes: `/scratch/zadoks_a/software/qe-build/recipes/README.md`.
Builds are scripted per toolchain (`qe-build`, one Slurm job each);
QE links its own hdf5/libxc statically, no legacy Intel build.

## Copy command (QE only)

```bash
rsync -a --no-o --no-g /scratch/zadoks_a/software/qe-build/software/qe/ /home/software/qe/
```

Keep the symlinks (`-a` without `-L`; QE uses `bin -> src/bin`).
`--no-o --no-g` keeps target ownership (`geiger_j`, group per umask)
instead of failing on `zadoks_a` chown over NFS. New `README.md`
overwrites the current one (still documents 7.3); 7.3 build dirs
are untouched.

## Held: FHI-aims

Do NOT copy `fhi-aims/` yet. Once in `/home/software`, every Thor
user can execute it; the licence check is open (Leo mail of 2026-10-26,
ServiceNow group request pending). When cleared: create the group,
copy, then `chgrp -R` plus `o-rwx`. See the FHI-aims question in
`/tmp/thor-leo-mail.md`.
