# Container support on the LMS cluster — architecture and runbook

## What we ended up with

Container support on the LMS cluster runs on rootless [Podman](https://podman.io/), with the `docker` CLI shim from the `podman-docker` package making `docker …` invocations transparently work. Image storage and container runtime layers live on the shared BeeGFS scratch filesystem (`/scratch`, 38 TB, visible identically on every node), using the `vfs` storage driver.

Concretely, every user runs Podman with this storage configuration in `~/.config/containers/storage.conf`:

```toml
[storage]
driver = "vfs"
rootless_storage_path = "/scratch/containers/$USER/storage"
```

Optional, once we start curating shared images:

```toml
[storage.options]
additionalimagestores = ["/scratch/containers/_shared/images"]
```

Storage layout on `/scratch`:

```
/scratch/containers/                          # mode 1777 (sticky, world-writable)
├── _shared/                                  # admin-curated, mode 0755 root-owned
│   └── images/                               # populated via `sudo podman --root … load -i …`
└── <user>/                                   # per-user, owned by user
    └── storage/                              # podman graphroot; vfs layout
        ├── libpod/db.sql                     # podman's per-user state DB
        ├── vfs/                              # full-copy layer trees (no overlay)
        ├── vfs-images/                       # image manifests
        └── vfs-containers/                   # container metadata
```

## Why `vfs` and not `overlay`

The "right" Podman storage driver for performance is `overlay` (kernel-level copy-on-write between image layers). We tried hard to make it work on BeeGFS and it doesn't, for reasons that are kernel-level and out of our control:

1. **Extended attributes.** Overlay needs xattrs for whiteout/opaque markers. BeeGFS shipped with xattrs disabled (`storeClientXAttrs = false` on metadata servers, `sysXAttrsEnabled = false` on clients). We enabled both during the 2026-05-08 maintenance window and that's now persistent — `setfattr`/`getfattr` round-trip cleanly on `/scratch`.
2. **Mount-point creation inside merged overlays.** Even with xattrs working, `runc` (the OCI runtime Podman invokes per container) tries to create mount targets like `/etc/resolv.conf` and `/run/.containerenv` inside the container's overlay-merged rootfs. Those operations fail on BeeGFS with `device or resource busy`. Same failure on the kernel `overlay` driver and on userspace `fuse-overlayfs`. The lower filesystem (BeeGFS) doesn't satisfy some semantic the overlay implementations assume.

We considered moving the graphroot to local disk per node (e.g. `/var/tmp/containers-$USER`) to use overlay. Two problems:

- Every node has `/var/tmp` LV-sliced to 2.2 GB. A 9.4 GB triqs image won't fit anywhere on local disk. Resizing the LVs cluster-wide is a system change PSI-IT scoped, not done lightly.
- Local-disk graphroots also lose cross-node sharing. An image loaded on `lms-login` would have to be re-loaded on each worker.

`vfs` sidesteps all of this. No overlay, no xattr requirement, no kernel-overlay-on-BeeGFS-quirks, full BeeGFS sharing. Cost: image pulls are slightly slower (each layer is a full directory copy with no dedup), and an image's on-disk size is roughly 2-3× its compressed tar size. On 38 TB of scratch that's fine.

## Why a per-user `~/.config/containers/storage.conf` and not a system-wide drop-in

We initially deployed `/etc/containers/storage.conf.d/10-lms.conf` via puppet's `files::files` with `rootless_storage_path` set there. It works for many things but **not for `rootless_storage_path` on RHEL 8.10's containers-common version (~v0.57)** — that key is treated as a per-user setting and the system drop-in is silently ignored. The user-level config (in `$HOME/.config/containers/`) is what actually takes effect.

Two ways to deploy:

1. **Manual one-liner per user.** Documented in the wiki. Works today.
2. **Skel + bulk-copy** (follow-up): drop a template at `/etc/skel/.config/containers/storage.conf` for new users, plus a one-shot script that copies it into each existing user's home with correct ownership. Pairs with `link-homes.sh`-style fan-out via pdsh. Not yet implemented.

## Why the BeeGFS xattr work was still worth doing

It didn't unblock overlay (we didn't know about the second blocker until we tried), but xattr support on `/scratch` is generally useful: `setfacl` ACLs, SELinux contexts on user files, future tools that depend on xattrs. It's a one-time cluster-wide flag flip and the cost was a brief metadata-server restart blip during a drained maintenance window. Net: no regret.

## subuid / subgid: cross-node first-run quirk

Rootless Podman maps the host user to a UID range inside container user namespaces, so that files inside the image with non-host UIDs (e.g. `_apt:100`) can be represented faithfully without the user having root. The mapping range comes from `/etc/subuid` and `/etc/subgid`, which are populated on a per-node basis on this cluster.

Observed state on 2026-05-08:

- `/etc/subuid` has one line per user who has ever run a container on that node, keyed by *numeric UID* with a stable subuid_start (same value across nodes for a given user — clearly hash-derived). The mechanism appears to be SSSD/shadow-utils auto-allocation triggered the first time a user invokes `podman` (or anything else that calls `getsubids`/`newuidmap`).
- The auto-allocation is **lazy**: a worker the user has never touched has no entry. The very first `podman run` on that worker fails with `lchown … invalid argument` (typically on `/etc/gshadow`) because the namespace setup races against the allocation. Re-running succeeds.
- The shipped `shadow-utils-4.6` (RHEL 8.10) and the corresponding `containers-common` look up subid entries *by username* and ignore by-UID lines. This is why the warning message says "no subuid ranges found for user 'geiger_j'" even when `48607:2239403008:65536` (= geiger_j by UID) is present.

Net effect: containers work cluster-wide today, but every user gets one transient `lchown` failure the first time they touch a previously-unvisited worker. Annoying but self-healing.

The proper fix — deploying by-username `/etc/subuid` / `/etc/subgid` files via puppet — is a deferred follow-up. Concrete plan, considerations, and rollout sequence in [subuid-rollout-plan.md](subuid-rollout-plan.md).

## How to populate the shared image store

When a user has an image others would benefit from (e.g. carta_a's triqs), an admin loads it once into the shared store rather than into the user's personal storage:

```bash
# As root, on any node mounting /scratch:
sudo podman --root /scratch/containers/_shared/images load -i /path/to/image.tar
sudo chmod -R o+rX /scratch/containers/_shared/images
```

After that, every user with `additionalimagestores = ["/scratch/containers/_shared/images"]` in their `storage.conf` sees the image in `podman images` without it taking any of their personal storage. They can `podman run` it directly.

**Note (current state):** the additionalimagestores line is intentionally not in the user-facing one-liner yet, because (a) the shared store has no images, and (b) Podman complains if `additionalimagestores` points at an empty directory. Add it to user configs once we have content there, or load `alpine` as a one-byte placeholder so the additional-store-init machinery doesn't throw.

## Setting up a new user for containers

For now (until skel-based deployment is in place), in addition to the existing user-onboarding steps:

```bash
# As the new user (or with sudo -u <user>) on lms-login:
mkdir -p /mnt/home/<user>/.config/containers
cat > /mnt/home/<user>/.config/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
rootless_storage_path = "/scratch/containers/$USER/storage"
EOF
chown -R <user>:<group> /mnt/home/<user>/.config
```

`/scratch/containers/<user>/` doesn't need pre-creation; the parent `/scratch/containers/` is mode 1777 (sticky), so Podman will create the user subdirectory itself on first invocation.

## Cleanup of the maintenance-window debris

The 2026-05-08 BeeGFS xattr rollout left some artefacts that are safe to delete:

- `/scratch/containers/<user>/storage.broken` and `storage.broken-overlay` — failed attempts at overlay-on-BeeGFS storage. `mv`'d aside rather than deleted because BeeGFS held them busy. Try:
  ```bash
  podman unshare rm -rf /scratch/containers/<user>/storage.broken*
  ```
  If still busy, leave them; they'll clear at the next reboot of `lms-login` (which is where the BeeGFS lock state lives). Cost: a few hundred MB of stale layer copies.
- `/var/tmp/containers-<user>` — local-disk graphroot from one of the test attempts. Same story: try `rm -rf`, leave if it complains.
- `~/aiida_projects/thor-dev/git-repos/hpc-admin/beegfs-xattr-rollout.md` — the runbook itself. Keep it for one rebuild-meta-server scenario, then delete. (Or keep it as a generic "how to drain + restart BeeGFS metadata services" runbook; only the xattr-flip sections are obsolete.)

## Troubleshooting

`podman info` shows the wrong graph driver and complains about driver mismatch:

> `User-selected graph driver "vfs" overwritten by graph driver "overlay" from database`

The user has a libpod sqlite database from a previous overlay attempt. Move the storage tree aside (deletion often fails on BeeGFS due to "device or resource busy"):

```bash
mv /scratch/containers/$USER/storage /scratch/containers/$USER/storage.old
```

Podman will create a fresh tree on next invocation, free of the cached driver setting.

`podman run` fails with `cannot re-exec process to join the existing user namespace`:

Stale rootless pause-process state from a previous Slurm job on the same node. The pause process was killed when the previous job ended, but its PID file wasn't cleaned up. Recovery (as the user):

```bash
rm -rf "$XDG_RUNTIME_DIR/libpod"
```

(Documented in the user-facing wiki section.)

`podman run` fails with `device or resource busy` creating a mountpoint inside the container rootfs:

This was the symptom of the overlay-on-BeeGFS issue. If it happens with the recommended `vfs` config, something else is wrong — verify with `podman info` that the graph driver is actually `vfs`. If `podman info` says `overlay`, see the previous troubleshooting entry.

`/scratch` becomes briefly unresponsive during BeeGFS metadata-server restarts:

Expected and brief (a few seconds). Clients retry transparently. If a job actively reading metadata happens to hit the restart window, it might log a transient error and recover. Don't restart both meta servers (thor1, thor2) simultaneously — clients only stay live if one is serving at all times.

## Provenance

The architecture decision history is in conversation context with Julian Geiger on 2026-05-07 and 2026-05-08. Key turning points: discovery that home-quota is too small for image storage (initial concern → motivated `/scratch` move); discovery that BeeGFS lacked xattrs (blocker → metadata-server flag flip); discovery that overlay-on-BeeGFS fails even with xattrs due to runc mountpoint creation (final blocker → switch to `vfs`); discovery that subuid is auto-populated lazily by-UID but old `containers-common` looks up by-username (deferred → puppet-managed by-username `/etc/subuid` rollout).
