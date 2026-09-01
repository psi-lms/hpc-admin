# Scripts inventory

Reference for everything in `scripts/`. Most scripts assume you run them
from your workstation (which has `pdsh` configured to reach the thors as
root via FQDN), unless noted otherwise. See
[cluster-ops-runbook.md](cluster-ops-runbook.md) for the underlying auth
and connectivity model.

## Configuration / data

### `extract-users.py`

Reads `aaa::admins` and `aaa::users` from `data-lms/compute_cluster.yaml`
(sibling repo), unions them, drops a hardcoded exclude list (legacy
accounts no longer with the lab), and writes the result to `scripts/USERS`.

Run whenever the user list in `compute_cluster.yaml` changes — most
other scripts in this repo iterate over `USERS`. Requires `pyyaml`.

```bash
python3 scripts/extract-users.py
```

### `USERS`

Output of `extract-users.py`. One username per line. Consumed by
`deploy-podman-storage-conf.sh`, `fix-user-group.sh`, and any future
per-user fan-out script. Note: the current implementation does not write
a trailing newline; consumers should use the `while read … || [[ -n ]]`
pattern to handle this gracefully.

## Cluster-wide ops

### `run-puppet.sh`

Fans out `sudo /opt/puppetlabs/bin/puppet agent -t` to every node in the
cluster (10 thors + lms-login + lms-mgmt) in **parallel** via `pdsh`.
Optional `exclude_nodes` array near the top to skip specific hosts.

Each `pdsh` call is backgrounded with `&` and the script does not
`wait`, so the prompt returns before puppet finishes. To check
completion, see the runbook section "Verifying a puppet run."

```bash
./scripts/run-puppet.sh
```

### `restart-BGFS.sh`

Stop or start the entire BeeGFS stack in the correct order. Stop:
clients → storage → metadata → management. Start: management → metadata
→ storage → clients. Only use for full cluster maintenance, not for
individual node intervention.

```bash
./scripts/restart-BGFS.sh stop
./scripts/restart-BGFS.sh start
```

### `enable-beegfs-xattrs-meta.sh`

Idempotent helper to flip `storeClientXAttrs = true` in
`/etc/beegfs/beegfs-meta.conf` on a metadata server (thor1 or thor2),
back up the existing file with a timestamp, and restart `beegfs-meta`.
Used during the 2026-05-08 maintenance window to enable xattr support
on `/scratch`. Designed to be re-run safely if a metadata server gets
re-bootstrapped via `beegfs-setup-meta` (which resets the flag to
`false`).

```bash
# scp to a meta server, then on that server as root:
bash /tmp/enable-beegfs-xattrs-meta.sh
```

The companion client-side flag (`sysXAttrsEnabled`) is puppet-managed
in `data-lms/compute_cluster.yaml` and rolls out to every node via
`run-puppet.sh`.

### `firecrest-bootstrap.sh`

One-time bootstrap for the FirecREST pilot on `lms-login`. Creates
everything secret-bearing that Puppet deliberately does not manage: the
`/etc/firecrest/secrets` tree, an ed25519 keypair per pilot user, the
service account secret, the Keycloak realm JSON and `keycloak.env`. Runs
**on the node as root**, unlike most scripts here, and must run *before*
the first puppet run so `files::files` finds its parent directories.

Idempotent: existing keys and secrets are kept rather than rotated. It
prints the generated credentials and the public keys, and appends nothing
to any user's `authorized_keys`, which is left as a deliberate manual step.

Edit `PILOT_USERS` at the top to add people. See
[firecrest-deployment.md](firecrest-deployment.md) for the surrounding
design and the activation runbook.

```bash
scp scripts/firecrest-bootstrap.sh lms-login.psi.ch:/tmp/
ssh lms-login.psi.ch 'sudo bash /tmp/firecrest-bootstrap.sh'
```

### `cluster-health-check.sh`

Single-shot audit collecting slurm node states, BeeGFS health, NFS
mount status, podman storage sizes, and obvious config drift between
nodes. Drafted 2026-05-08 but **not yet wired into a puppet timer** —
intended to run monthly from `lms-mgmt` once vetted.

## Per-user fan-out

### `link-homes.sh`

Creates `/home/<user>` → `/mnt/home/<user>` symlinks on every node, so
users get the conventional `/home/<user>` path resolving to the
NFS-mounted real home. Runs over `pdsh` to the full node list.

### `deploy-podman-storage-conf.sh`

Pushes the canonical `~/.config/containers/storage.conf` (vfs driver,
graphroot on `/scratch`) into every existing user's home directory.
Idempotent: skips users who already have a file (so it never overrides
a user's own customization), skips puppet-only accounts not in the
local passwd database, and skips users who don't have a home dir yet.

Run as root on `lms-login` (where `/mnt/home` is mounted). Companion to
the puppet-managed `/etc/profile.d/podman-storage-conf.sh` that handles
new users on first login. This script just speeds the rollout for
existing users instead of waiting for them to ssh in.

```bash
scp scripts/deploy-podman-storage-conf.sh scripts/USERS lms-login.psi.ch:/tmp/
ssh lms-login.psi.ch 'sudo bash /tmp/deploy-podman-storage-conf.sh'
```

### `fix-user-group.sh`

Maps a user's slurm account (`prio` → `msd`, `normal` → `lms`) to the
matching unix group, chowns and re-setgid's their `/mnt/home/<user>`
and `/scratch/<user>` trees. Needed for users created with
`unx-nogroup` as primary group, where shared-group access patterns
break.

**Status: draft.** Needs a `--dry-run` flag and a smoke test on a
single user before bulk fan-out.
