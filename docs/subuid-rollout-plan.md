# subuid / subgid puppet rollout plan

Deferred follow-up from 2026-05-08. Goal: pre-allocate per-user
`/etc/subuid` and `/etc/subgid` ranges cluster-wide so rootless Podman
on a freshly-touched worker doesn't fail with `lchown … invalid
argument` on the user's first container run.

See [containers-architecture.md](containers-architecture.md#subuid--subgid-cross-node-first-run-quirk)
for the diagnostic story.

## What we observed

- `/etc/subuid` on every node has one *by-UID* line per user who has
  ever run a container on that node. The subuid_start values are
  identical across nodes for a given user (e.g. `48607:2239403008:65536`
  for geiger_j on both lms-login and thor1) → hash-derived, not
  random. The mechanism is most likely SSSD's `subid_provider` or a
  shadow-utils hook, allocating lazily on first invocation of
  `getsubids` / `newuidmap`.
- `shadow-utils-4.6` (RHEL 8.10) and the corresponding podman /
  containers-common look up subid entries **by username only** —
  by-UID lines are invisible to them. The auto-allocated by-UID line
  exists but doesn't satisfy podman's lookup.
- Net effect: every user gets a single transient `lchown` failure the
  first time they run a container on a previously-unvisited worker.
  The failure is also what triggers the by-UID allocation, so
  re-running the same command works. Annoying but self-healing.

## Proposed rollout

Add **by-username** `/etc/subuid` and `/etc/subgid` lines for every
LMS user, deployed identically to all 12 nodes via Hiera. Coexists with
the existing by-UID auto-allocations (different format, different
lookup key) so nothing already working breaks.

### Step 1 — understand the existing mechanism first

Before stomping on the file with puppet, confirm what's writing to it:

```bash
grep -i subid /etc/sssd/sssd.conf
grep -rl pam_subid /etc/pam.d/
ls -la /etc/sssd/conf.d/ /etc/sssd/sssd.conf.d/ 2>/dev/null
rpm -qf /usr/lib/security/pam_subid.so 2>/dev/null
```

If SSSD is the source, document the config so future-us doesn't fight
it. If it's a `useradd`-style hook (less likely), same.

### Step 2 — generator script

Add `scripts/generate-subid-files.py`:

- Read `scripts/USERS`.
- For each user `i` (sorted alphabetically for stable ordering), assign
  range start = `200000 + i * 65536`. 65536 wide each. 41 users today =
  range tops out around `2.9M`, well under any kernel UID limit.
- Write `subuid` and `subgid` to `data-lms/files/etc-subuid` and
  `data-lms/files/etc-subgid` (or whatever naming the profile uses).
- Idempotent: same user list ↔ same files, byte-for-byte.

Each line: `<username>:<start>:65536`.

### Step 3 — Hiera entries

In `data-lms/compute_cluster.yaml`, under the existing `files::files`
block, add entries for `/etc/subuid` and `/etc/subgid` referring to
the generated files. Owner root, group root, mode 0644 (the default
shadow-utils permissions).

### Step 4 — deploy and verify

1. Run `scripts/generate-subid-files.py` to produce the files.
2. `git add` the generated files plus the Hiera change in `data-lms`,
   commit, push.
3. `./scripts/run-puppet.sh` from your workstation.
4. Pick an *untouched* worker (one where you haven't run a container
   yet — check with
   `srun --partition=normal --time=00:01:00 --nodelist=thorN bash -c
   'grep ^geiger_j /etc/subuid; echo done'`). Run a non-trivial
   `podman run python:3.12-slim …` via `srun` against it. It should
   succeed on first try.
5. Repeat for at least one other untouched worker.

If verification passes, the first-run quirk is gone for everyone going
forward.

## Considerations

- **Existing auto-allocated by-UID lines stay.** Don't try to clean
  them up — they're harmless, and other tools (rootless podman across
  podman versions, future containers) may keep using them. Coexistence
  is fine.
- **New users.** Whenever `extract-users.py` is re-run after a user is
  added, also re-run `generate-subid-files.py` and re-run puppet.
  Could automate by chaining them in a single `update-users.sh`
  wrapper.
- **Range collisions.** If we ever add SSSD-side managed subid ranges
  (e.g. via `subid_provider = sss`), confirm they don't overlap with
  the static `200000+N*65536` we're allocating. With 41 users we use
  `200000–2.9M`; SSSD's defaults are typically much higher. Should be
  fine but worth a sanity check during step 1.
- **Range conflicts with system services.** Reserve `<200000` for the
  system; our ranges start at `200000`. Existing `/etc/subuid` lines
  on lms-login (`0:2000000000:…`, `48607:2239403008:…`) sit at much
  higher subuid_start values, so no clash.

## When to actually do this

Not urgent. Self-healing on first-run is annoying but not blocking.
Schedule for the next maintenance window or a quiet morning, after a
fresh look at step 1 (the SSSD investigation). Pair with the related
deferred follow-ups: wiring `cluster-health-check.sh` into a puppet
timer, and validating `fix-user-group.sh`.
