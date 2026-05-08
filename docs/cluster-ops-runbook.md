# LMS cluster ops runbook

Operational primitives for day-to-day administration of the LMS cluster
(1× lms-mgmt, 1× lms-login, 10× thor[1-10]). Focuses on the things that
took us painful re-discovery during the 2026-05-07 / 2026-05-08
maintenance window — the auth landscape, the connectivity model, the
order-sensitive procedures.

## Auth and connectivity model

Three machines, three different authentication realities:

- **Your workstation** (`mpc3152` etc.) — has `pdsh` with the `ssh` rcmd
  module, and `root@workstation` has SSH keys to `root@thor[1-10].psi.ch`
  via FQDN. Use `sudo pdsh -w 'thor[1-10].psi.ch' …` for most cluster-wide
  ops as root. Short hostnames (`thor[1-10]`) fail with "Host key
  verification failed" because root's `known_hosts` only has FQDN
  entries — use the FQDN form.
- **`lms-login.psi.ch`** — your interactive landing pad. `geiger_j` has
  `sudo` here. `pdsh` is installed but defaults to `rsh` (no `ssh`
  module installed; check with `pdsh -h`), so it cannot reach the thors
  unless you scope the command to lms-login itself. Don't use `pdsh`
  from here for cluster-wide ops; go back to your workstation for
  those.
- **`thor[1-10]`** — workers. Regular users (including you) cannot ssh
  in directly; access is mediated by `pam_slurm_adopt`, i.e. only via
  an active slurm allocation. Root SSH (from authorized origins) does
  work for admin commands.

Two specific gotchas:

- **Root SSH into `lms-login` is disabled.** `sudo scp foo
  root@lms-login.psi.ch:/tmp/` will close the connection immediately
  after host-key acceptance. Workaround: `scp` as yourself, then ssh in
  interactively and `sudo` from there.
- **`sudo pdsh` from your workstation will prompt for your sudo
  password**, but only on the workstation side; the resulting `pdsh`
  child runs as root (workstation's root) and uses root's keys to
  reach the thors. So you enter your password once at the start, not
  per-host.

## Drain and resume nodes

Before any cluster-wide work that affects running jobs (filesystem
remounts, kernel changes, BeeGFS server restarts):

```bash
# On lms-login or lms-mgmt as a sudoer:
sudo scontrol update NodeName=thor[1-10] State=DRAIN \
    Reason="<short reason>"

# Verify state — drained means no new jobs accepted; draining means
# still finishing current jobs:
sinfo -o '%n %T %r'

# Check what's still running:
squeue
```

Wait until `squeue` shows no `R` (running) jobs on the workers you
intend to disturb. `PD` (pending) is fine — those will dispatch once
you resume.

Resume:

```bash
sudo scontrol update NodeName=thor[1-10] State=RESUME
sinfo -o '%n %T %r'   # should be all idle/mix
```

## Run puppet cluster-wide

```bash
./scripts/run-puppet.sh
```

The script fans out 12 `pdsh` calls in parallel and **does not
`wait`** — your prompt returns before puppet finishes. To verify
completion:

```bash
# Are any agents still running?
sudo pdsh -w 'thor[1-10].psi.ch,lms-login.psi.ch,lms-mgmt.psi.ch' \
    'pgrep -af "puppet agent" || echo "(idle)"' 2>&1 | sort
# All "(idle)" means done.

# Did your specific change land?
sudo pdsh -w '<all-nodes>' 'test -f /path/to/expected/file && echo OK || echo MISSING' 2>&1 | sort
```

If a node hangs in "running" indefinitely, ssh in as root and look at
`journalctl -u puppet -n 200`.

## Remount /scratch cluster-wide

After a Hiera change to `/etc/beegfs/beegfs-client.conf` or to
`/etc/beegfs/beegfs-mounts.conf`, puppet rewrites the file but the
running BeeGFS kernel module still uses the old config — you have to
remount `/scratch` to pick up the change:

```bash
# Per node, as root:
umount /scratch
systemctl restart beegfs-client
```

The systemd unit handles the mount itself; don't try to use `mount
/scratch` (it's not in `/etc/fstab`). If `umount` reports "device is
busy":

```bash
lsof /scratch    # find offenders
# kill or work around them, then retry. As a last resort (LMS-specific):
fuser -km /scratch    # forcibly kill processes using /scratch
umount -l /scratch    # lazy unmount
rmmod beegfs          # only after all references dropped
systemctl restart beegfs-client
```

`lms-login` is the most likely place to hit "busy" because users have
ongoing shells with `cwd` inside `/scratch`. We hit exactly that on
2026-05-08; the fix was `kill -9` of the user's bash → `rmmod beegfs`
→ `systemctl start beegfs-client`.

## BeeGFS metadata server restarts

BeeGFS metadata is served by `thor1` and `thor2` in HA. Restart **one
at a time** so clients always have a server to talk to. Manual
procedure:

```bash
ssh root@thor1.psi.ch
cp /etc/beegfs/beegfs-meta.conf /etc/beegfs/beegfs-meta.conf.bak.$(date +%F)
# edit, then:
systemctl restart beegfs-meta
systemctl status beegfs-meta
# confirm "active (running)" and a recent timestamp before touching thor2
```

`scripts/enable-beegfs-xattrs-meta.sh` automates the xattr-specific
case (idempotent; backs up the conf with a timestamp).

## Slurm interaction with running jobs

To peek at what a user's job is doing on a worker:

```bash
# Only works as the job owner (or with admin override):
srun --jobid=<jobid> --overlap bash -c 'ps -ef -u <user>'
```

As an admin investigating someone else's job, the cleanest path is to
ssh as root to the worker and run `ps` directly. From your workstation:

```bash
sudo ssh root@thor4.psi.ch 'ps -ef -u <user>'
```

To read a user's submit script when investigating their setup:

```bash
ssh lms-login.psi.ch 'sudo cat /mnt/home/<user>/path/to/submit.sh'
```

## File deployment via Hiera `files::files`

The puppet profile module accepts a `files::files` hash mapping
absolute paths to `{owner, group, mode, content}`. Used for system
files like `/etc/profile.d/*.sh`, `/etc/beegfs/*.conf`,
`/etc/slurm/prolog_xdg_runtime.sh`. Limitations we've hit:

- **Does not create parent directories** for new paths. If you need
  `/etc/skel/.config/containers/storage.conf`, the parent dirs must
  exist. Workarounds: deploy to an existing path (e.g. a
  `/etc/profile.d/*.sh` snippet that runs at login), or add a separate
  puppet manifest with `file { '/path': ensure => directory }`.
- **Does not iterate over users.** No `${user}` variable, no per-user
  fan-out. For per-user concerns, deploy a `/etc/profile.d/*.sh`
  snippet that does the work at login time, or use a one-shot
  bash-loop script in this repo (e.g.
  `scripts/deploy-podman-storage-conf.sh`).
- **`rootless_storage_path` is per-user only.** A
  `/etc/containers/storage.conf.d/*.conf` system drop-in is silently
  ignored for that key in `containers-common` 0.57 (RHEL 8.10). Deploy
  the user-level config instead, ideally via a profile.d snippet.

## "Maintenance complete" checklist

After any cluster-wide window:

1. `sudo scontrol update NodeName=thor[1-10] State=RESUME` — let new
   jobs dispatch again.
2. `sinfo -o '%n %T %r'` — confirm all nodes idle/mix.
3. `squeue` — confirm pending jobs are dispatching, not stuck.
4. Smoke-test the actual change — don't trust that puppet "ran cleanly"
   means the user-visible behavior is right; run the user-level
   verification command (e.g. `podman info`, `setfattr`-on-`/scratch`).
5. Slack post in the maintenance thread: "back up, here's what changed,
   here's what (if anything) users need to do."
