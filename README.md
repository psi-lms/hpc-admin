# LMS / Thor cluster admin tooling

Quality-of-life infrastructure for the Thor cluster (and historically also Thanos): operational scripts, fan-out helpers, and architecture / runbook docs that capture the parts of the cluster that aren't otherwise version-controlled.

Most scripts here assume you run them from your **local workstation** (`mpc3152` etc.), where `pdsh` is configured with the `ssh` rcmd module and root has SSH keys to every thor node via FQDN. See `docs/cluster-ops-runbook.md` for the full auth and connectivity model.

## Docs

- `docs/cluster-ops-runbook.md` — operational primitives: how to drain/resume nodes, run puppet cluster-wide, remount `/scratch`, restart BeeGFS metadata servers, deploy files via Hiera. Start here for any maintenance window.
- `docs/containers-architecture.md` — final design of the rootless-Podman setup on the cluster: vfs storage on `/scratch` (BeeGFS), per-user `~/.config/containers/storage.conf` auto-deployed via puppet, why overlay-on-BeeGFS was rejected, troubleshooting, onboarding.
- `docs/scripts.md` — inventory of every script in `scripts/`, with purpose, prerequisites, and example invocation.
- `docs/subuid-rollout-plan.md` — deferred follow-up: pre-allocate per-user `/etc/subuid` / `/etc/subgid` ranges via puppet to eliminate the first-run-on-unvisited-worker `lchown` quirk.

## Scripts at a glance

See `docs/scripts.md` for full descriptions.

| Script | Purpose |
|---|---|
| `extract-users.py` | Refresh `USERS` from `data-lms/compute_cluster.yaml` |
| `run-puppet.sh` | Fan out `puppet agent -t` to every cluster node |
| `restart-BGFS.sh` | Stop / start the entire BeeGFS stack in correct order |
| `enable-beegfs-xattrs-meta.sh` | Idempotent `storeClientXAttrs=true` flip on a meta server |
| `cluster-health-check.sh` | Single-shot cluster-wide health audit (draft) |
| `link-homes.sh` | Per-node `/home/<user>` → `/mnt/home/<user>` symlinks |
| `deploy-podman-storage-conf.sh` | Push canonical podman storage.conf into existing user homes |
| `fix-user-group.sh` | Map slurm account to unix group; chown home and scratch (draft) |

## Prerequisites

- `pdsh` with the `ssh` rcmd module (`apt install pdsh-rcmd-ssh` or equivalent). If you see `rcmd: socket: Permission denied`, create `/etc/pdsh/rcmd_default` containing the literal string `ssh` (e.g. `echo ssh | sudo tee /etc/pdsh/rcmd_default`).
- Root SSH keys on your workstation pre-authorized for `root@thor[1-10].psi.ch` (FQDN).
- `pyyaml` for `extract-users.py`.
- `sudo` for the `pdsh` calls (root's keys are what reach the thors).
