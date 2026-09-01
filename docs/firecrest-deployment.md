# Deploying FirecREST on the LMS cluster

Status: design + pilot implementation ready, not yet applied.
Date: 2026-08-14.
Target host: `lms-login.psi.ch`.

## What FirecREST is

FirecREST is a REST API that sits in front of an HPC cluster. A client (a script, a web UI, AiiDA, Airflow, JupyterHub) makes HTTP calls like "submit this job", "list this directory", "download this file", and FirecREST translates them into `sbatch` / `squeue` / `ls` / `cat` executed **as the calling user** on a login node. It is a proxy, and it holds no state of its own: no user database, no job database, no file store.

Two consequences shape the entire deployment:

- FirecREST does not authenticate anybody. It only *verifies* JSON Web Tokens signed by an external identity provider, and reads the username out of a claim in that token. An OIDC provider is therefore a hard prerequisite, not an optional extra.
- FirecREST must be able to become an arbitrary user over SSH. It does that either with a private key per user, or by asking a certificate authority to mint a short-lived SSH certificate for that user. This is the security-critical part of the design.

Everything else (object storage, tracing, fine-grained authorization) is optional.

## How the authentication actually works

This is the part that decides how much infrastructure the deployment needs, so it is worth being precise about.

FirecREST never sees a password. It receives an HTTP header, `Authorization: Bearer <token>`, where the token is a **JWT** (JSON Web Token): three base64 chunks separated by dots, holding a header, a payload of **claims** (`preferred_username`, `exp`, and so on), and a cryptographic signature.

What FirecREST does with it is narrow:

1. Read the `kid` (key id) from the token header.
2. Look up the matching **public** key.
3. Verify the signature, and that the token has not expired.
4. Read one claim, named by `username_claim`, and treat that string as the cluster username.
5. SSH into the cluster as that user.

Step 4 is the whole security model: whoever can produce a validly signed token with `preferred_username: carta_a` gets to act as `carta_a` on the cluster. The signing key is therefore as powerful as every user's password combined.

The vocabulary, since the OAuth2 and OIDC specs are dense and the terms recur throughout the config:

- **Identity provider (IdP)**: the service that authenticates humans and issues signed tokens. Keycloak is one implementation. OIDC (OpenID Connect) is the standard it speaks, layered on OAuth2.
- **Client**: a registered application allowed to request tokens. A `client_id` identifies it, a `client_secret` proves it. This is not a user account; it is an application's credential.
- **Token endpoint** (`token_url`): the URL you POST credentials to in order to receive a token.
- **JWKS endpoint** (`public_certs`): a URL serving the IdP's **public** keys as JSON, so that anyone can verify a signature without being able to forge one. This is ordinary public-key cryptography: the IdP holds the private half and signs, FirecREST holds the public half and only verifies.
- **Grant / flow**: how a token is obtained. `client_credentials` (an application authenticating as itself), `password` (username and password posted directly, convenient and discouraged in production), `authorization_code` (the browser redirect dance that a human login uses).

The CSCS setup you have seen fits exactly here. Generating a "FirecREST client ID and secret" on the CSCS web page is **registering an OAuth2 client against CSCS's identity provider**. The `client_id` and `client_secret` are then exchanged at CSCS's token endpoint for a JWT, which is sent to CSCS's FirecREST. So yes, that is the same OIDC machinery, with CSCS operating the IdP so users never think about it.

One subtlety that trips people up. Under `client_credentials` there is no human in the flow, so the token's subject is the *client*, not a person. Sites therefore configure a mapper on the IdP that writes the cluster username into a claim. That is why `username_claim` is configurable: it names whichever claim the local IdP happens to put the username in.

The practical consequence for this cluster: FirecREST needs a **public key and a claim**, and nothing forces that key to come from a full identity provider. Anything that can sign a JWT and publish the matching public key will do.

## v1 versus v2: use v2

The clone at `~/aiida_projects/firecrest/git-repos/firecrest` is **FirecREST v1** (`eth-cscs/firecrest`, version 1.16.6). v1 is a fleet of seven Flask microservices (certificator, compute, status, storage, tasks, utilities, reservations) behind a Kong gateway, with Redis for task persistence, configured through roughly 80 `F7T_*` environment variables. It is heavy and effectively in maintenance.

The docs you linked are **FirecREST v2** (`eth-cscs/firecrest-v2`, currently 2.5.6), now cloned at `~/aiida_projects/firecrest/git-repos/firecrest-v2`. v2 is a single asyncio FastAPI application in one container, configured by one YAML file. No Kong, no Redis, no per-service containers. Job and file state is read live from Slurm and the filesystem rather than cached.

For a ten-node cluster, v2 is the only sensible choice. The rest of this document is v2 only.

Note that the upstream install page only documents the Kubernetes/Helm path. That is a documentation gap, not a requirement: the application is an ordinary container with one config file, and the Helm chart is a thin wrapper around exactly that. Running it under systemd is fully supported by the software, just not written up.

## What v2 requires

From `src/firecrest/config.py`, the required top-level fields are `auth`, `ssh_credentials`, and per cluster `name`, `ssh`, `scheduler`, `service_account`, `probing`.

| Component | Required? | Notes |
|---|---|---|
| FirecREST API container | yes | `ghcr.io/eth-cscs/firecrest-v2`, one process, stateless |
| OIDC identity provider | **yes** | `auth.authentication` has no default |
| SSH credentials | **yes** | static per-user keys, or an SSH CA service |
| Service account | **yes** | an OIDC client-credentials client, used by FirecREST's own health checks |
| Slurm reachable over SSH | yes | `connection_mode: ssh` runs the CLI; no `slurmrestd` needed |
| S3 object storage | no | `data_operation.data_transfer` defaults to `None`. Without it, file ops up to `max_ops_file_size` (5 MB default) stream through the API and larger transfers are unavailable |
| OpenFGA authorization | no | defaults to `None`; without it any authenticated user reaches any endpoint, and the cluster's own POSIX permissions do the real enforcement |
| Tracing / structured logging | no | off by default |

## What the LMS cluster already provides

Verified on `lms-login.psi.ch` on 2026-08-14:

- RHEL 8.10, podman 4.9.4-rhel, and critically the **quadlet generator is present** at `/usr/lib/systemd/system-generators/podman-system-generator`. Quadlet landed in podman 4.4, so dropping a `.container` file into `/etc/containers/systemd/` yields a real systemd service. `/etc/containers/systemd/` exists and is empty.
- `ghcr.io` and `quay.io` are reachable (HTTP 401 from `/v2/`, which is the expected unauthenticated response), so image pulls work with no proxy configuration.
- `firewalld` is inactive, so there is no host firewall to open. Whatever port is published is reachable from wherever the PSI network allows, which is an argument for binding to loopback initially.
- `/etc/ssh/sshd_config.d/` exists and holds an `empty.conf` placeholder carrying the comment "empty to avoid SSHD coredump on RHEL8.6". That placeholder only makes sense if `sshd_config` contains an `Include` of that directory, so an SSH CA drop-in later will not have to fight the puppet-managed `sshd_config` (which is not world-readable, hence the inference).
- `slurmrestd` is inactive. Slurm is 25.11.7.
- Filesystems: `/mnt/home` (NFS `thor-nfs:/home`, 990 GB) holds user homes, `$HOME` is `/mnt/home/<user>`; `/scratch` (BeeGFS, 35 TB) is the scratch space.
- Partitions: `short` (thor1-2, 2 h limit), `normal` (thor3-10, 2 d limit, default).
- `sshd` listens on `0.0.0.0:22`.
- `files::files` is **deep-merged** across the Hiera hierarchy. Confirmed empirically: entries defined only in `compute_cluster.yaml` (`beegfs-mounts.conf`, `beegfs-client.conf`, `conda.sh`, `podman-storage-conf.sh`) are all present on `lms-login` alongside the host-level `beegfs-helperd.conf`. So host-level additions accumulate rather than replace.

One caveat: rootful podman stores images under `/var/lib/containers`, and `/var` is a 8 GB logical volume with 5 GB free. The two images total roughly 1 GB, which fits, but this is not a filesystem with room to grow. If image count ever increases, point podman's `graphroot` elsewhere.

## Does any of this depend on CSCS?

No. FirecREST is BSD-3 licensed software that runs entirely on your own infrastructure. Checked on 2026-08-31: the only occurrences of `cscs.ch` anywhere in `src/` are author email addresses in a `pyproject.toml`, and the only outbound URLs referenced in the code are documentation links plus `s3.amazonaws.com`, which is a default that is used only if S3 data transfer is configured. Nothing phones home, and there is no CSCS account, licence, or service in the request path.

The only things you fetch from elsewhere are the container images, from `ghcr.io`. Everything else runs locally.

A FirecREST client ID and secret issued by CSCS is a credential for **CSCS's** deployment, talking to **CSCS's** identity provider and **CSCS's** clusters. It has no bearing on a deployment of your own.

## Three ways to run this, in increasing commitment

Decided on 2026-08-31 not to involve PSI IT, since this is a small internal test cluster. That rules out a PSI-operated identity provider and leaves three self-contained options.

### Option 0: fully local sandbox, no cluster involved (start here)

The repo's `docker-compose.yml` brings up a complete self-contained environment: a **dummy single-node Slurm cluster**, a real Keycloak with a pre-seeded realm, and FirecREST. Nothing outside the workstation is touched.

```bash
cd ~/aiida_projects/firecrest/git-repos/firecrest-v2
F7T_HOST_IP=127.0.0.2 docker compose up -d keycloak slurm firecrest
```

`F7T_HOST_IP` moves every published port onto a second loopback address. Without it the stack tries to bind `127.0.0.1:8080` for Keycloak, which collides with whatever else is on 8080 (`odysseus-searxng-1`, on this workstation). Container-to-container traffic is unaffected, since that goes over the compose network.

Get a token with the shipped test credentials and call the API:

```bash
TOKEN=$(curl -s -X POST http://127.0.0.2:8080/auth/realms/kcrealm/protocol/openid-connect/token \
    -d grant_type=client_credentials \
    -d client_id=firecrest-test-client \
    -d client_secret=wZVHVIEd9dkJDh9hMKc6DTvkqXxnDttk \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.2:8000/status/systems
```

The shipped config defines three clusters against the dummy container: `cluster-slurm-ssh` (CLI over SSH, the closest analogue to how LMS would run), `cluster-slurm-api` (via `slurmrestd`, useful for evaluating that path without enabling it on the real cluster), and `cluster-pbs`, which stays unhealthy unless the `pbs` container is started too.

The token maps to cluster user `fireuser`: the realm sets the `sub` claim to that, and the config's `username_claim` is `sub`.

Verified on 2026-08-31: both Slurm clusters report scheduler, ssh and filesystem healthy; job 1 submitted over HTTP to `cluster-slurm-ssh` ran as `fireuser` and completed with exit 0; its output was read back through `/filesystem/.../ops/tail`. Wrapped in `/tmp/firecrest-local-up.sh`.

This is the right place to start: it exercises the whole stack, costs nothing, and risks nothing.

### Option A: the upstream demo container (needs a real cluster)

**This image contains no cluster.** Verified by inspecting the running container: no `sbatch`, `squeue`, `sinfo`, `slurmctld` or `slurmd` anywhere, and supervisord runs exactly three processes (the launcher, FirecREST, and the web UI). It is a FirecREST frontend plus a throwaway identity provider that must be pointed at an existing cluster over SSH, which is what upstream means by "connect to your local HPC cluster using your personal credentials".

So this option cannot give a self-contained sandbox. Use Option 0 for that. Reach for the demo image only when the goal is specifically to drive the **real** LMS cluster through FirecREST without deploying anything on it.

Upstream ships an all-in-one evaluation image that bundles a miniature identity provider, FirecREST, and a web UI, and which is explicitly designed to point at **your own** cluster:

```bash
podman run -p 8025:8025 -p 5025:5025 -p 3000:3000 \
    --pull always ghcr.io/eth-cscs/firecrest-v2-demo:2.6.0
```

Then open <http://localhost:8025/>. It asks for a cluster hostname, a username, and an SSH private key, checks it can reach the scheduler, writes itself a config, and starts FirecREST plus a UI on port 3000.

What it is doing under the hood, from `build/demo-launcher/src/launcher/main.py`: generating an RSA keypair in memory at startup, serving the public half at `/certs` as a JWKS, and serving `/token` which hands back a signed JWT for **whatever `client_id` you ask for, with no verification whatsoever**. The classes are literally named `UnsafeSettings`, `UnsafeSSHUserKeys`. Tokens are valid for 360 days.

So this is an evaluation toy and must never be exposed to a network. Run it on your workstation, pointed at `lms-login`, over a tunnel or from inside the PSI network. Its value is that it answers "is FirecREST worth deploying" in ten minutes with no commitment: no puppet, no commit, no container on a shared host.

It does need an SSH private key for a real cluster account, so use a purpose-made key rather than your everyday one, and remove it from `authorized_keys` afterwards.

#### Run on 2026-08-31: it works, with two upstream bugs

Done on the Ubuntu 24.04 workstation with Docker 29.2.1, against the real cluster. `lms-login.psi.ch` resolves to 129.129.162.121 and TCP 22 is reachable from there, so no tunnel was needed. A dedicated `~/.ssh/thor/firecrest-demo-key` (ed25519) was generated and appended to `authorized_keys` on `lms-login`.

Results, all through the HTTP API rather than SSH:

- `/status/systems`: scheduler, ssh and filesystem health checks all green, scheduler reporting `lms-mgmt.psi.ch UP`.
- `/status/lms/nodes`: all 10 thor nodes, 48 CPUs each.
- `/filesystem/lms/ops/ls`: correct listing of `/mnt/home/geiger_j`.
- `POST /compute/lms/jobs`: job 661616 submitted to the `short` partition, ran on thor1 as `geiger_j`, `COMPLETED` with exit code 0.
- `/filesystem/lms/ops/tail`: job output read back correctly.

Two upstream defects found in `firecrest-v2-demo:2.6.0`, both worked around in `/tmp/firecrest-demo-up.sh`:

1. **The API cannot start after `/boot`.** The launcher writes its config with `yaml.dump()` over a pydantic `model_dump()`, so enum members serialise as `!!python/object/apply:...TokenEndpointAuthMethod` tags. `firecrest.config` then loads that file with `yaml.safe_load`, which refuses those tags, and the process crash-loops with `ConstructorError`. Workaround: rewrite the generated config converting enums to their values. The proper fix upstream is `model_dump(mode="json")`.
2. **`/boot` 500s on a supervisor race.** It stops the `firecrest` process only when the state is exactly `RUNNING`, so calling it while the process is `STARTING` raises `ALREADY_STARTED`. Harmless, since the config it writes is what matters.

A third, smaller one worth knowing: `/filesystem/{system}/ops/view` defaults its `size` parameter to `max_ops_file_size` and then rejects sizes with a strict `<`, so the default always fails with "`size` value must be less than 1048576 bytes". Pass an explicit `&size=N`, or use `/ops/tail`.

Reproduce the whole thing with `/tmp/firecrest-demo-up.sh`, which starts the container on loopback, configures it against the cluster, applies the config fix, restarts the API and prints the health check.

The web UI on port 3000 stays `FATAL`; it was not investigated, since the API is the interesting part.

### Option B: static signing key, no identity provider (recommended for the real pilot)

`public_certs` takes a list of URLs, and FirecREST's auth code mounts a `file://` adapter on its HTTP session (`src/lib/auth/authN/OIDC_token_auth.py`, `s.mount("file://", FileAdapter())`). So a JWKS **file on disk** is a valid source of verification keys, and no identity provider needs to exist.

Verified on 2026-08-31 by driving FirecREST's own `OIDCTokenAuth` class directly: it loaded one key from a `file://` JWKS, accepted a locally minted token and resolved `preferred_username` to the right cluster user, and rejected a token with a tampered signature (`JWTError`).

What this needs:

- An RSA keypair generated once. The private half signs tokens and never leaves the admin's hands; the public half is published as `/etc/firecrest/jwks.json`.
- `public_certs: ["file:///run/secrets/jwks.json"]` in the config.
- `token_url` still has to be present, because the config model requires it, but nothing calls it. It is used only by the health-check probing and to populate the Swagger UI's "Authorize" button.
- **`probing.services` must be omitted.** `src/firecrest/dependencies.py:198` gates health enforcement on `if not self.ignore_health and system.probing.services:`, so leaving `services` unset disables health checks entirely, and with them the only code path that would try to reach `token_url`. Keeping `interval_check` alone is fine.
- A small script to mint tokens, run by an admin when someone needs one.

Two helper scripts exist for this, both tested on 2026-08-31 against FirecREST's own `OIDCTokenAuth`:

- `/tmp/firecrest-make-jwks.py`, run once as root. Generates the keypair, writes `signing-key.pem` (mode 0400) and `jwks.json` (mode 0444) into `/etc/firecrest/secrets`, both owned by UID 5678. Refuses to overwrite an existing key, since regenerating invalidates every token already issued.
- `/tmp/firecrest-mint-token.py <username> [--hours N]`, run as root whenever someone needs a token. Prints a JWT to stdout.

A token is a bearer credential: whoever holds it acts as that user until it expires. Hand it over the way you would hand over a password, and prefer short lifetimes.

Trade-offs, stated plainly. Gained: one container instead of two, no H2 database, no realm JSON, no identity provider to patch or back up, and no cluster-wide health checks to debug. Lost: token issuance is a manual admin step, there is no way for a user to log in and get their own token, revocation means rotating the signing key and reissuing everyone, and health checks are off so a broken cluster surfaces as failing requests rather than an unhealthy status.

For a cluster of this size where the admin knows every user personally, that trade is clearly worth it.

### Option C: self-hosted Keycloak

A real identity provider, running as a second container. This is what is currently staged in `compute_cluster/lms-login.psi.ch.yaml`.

Worth it once users should obtain their own tokens without an admin in the loop, once tokens need to expire and be refreshed properly, or once something else on the cluster wants single sign-on. Until then it is a database, a realm, an admin console and a patching obligation in exchange for capabilities nobody is using.

Note the staged version runs `start-dev` with `KC_DB=dev-file`, an H2 file store. Fine for a pilot, and it must become `start` with PostgreSQL before anyone depends on it.

### Recommendation

Start with Option 0, the fully local sandbox, to decide whether FirecREST earns a place at all. It touches nothing outside the workstation. Reach for Option A only if the question becomes specifically "does this work against *our* cluster", and note that it requires putting a key on `lms-login` and handing the private half to a container whose own classes are named `Unsafe*`.

If FirecREST earns its place, deploy Option B as the standing pilot. Move to Option C only when a concrete need appears, which for a ten-node group cluster may well be never. Migration between B and C is three config keys (`token_url`, `public_certs`, `username_claim`), so nothing is locked in.

## Chosen pilot design

Decisions taken on 2026-08-14:

- **Identity provider**: self-hosted Keycloak, as a second container on `lms-login`. No dependency on PSI IT, full control, fastest path to something working.
- **SSH credentials**: `SSHStaticKeys`, a dedicated keypair per pilot user. Understood to be the throwaway option; see the migration path below.
- **Everything binds to loopback.** Access during the pilot is through an SSH tunnel. Nothing is exposed on the PSI network until TLS and a reasoned exposure decision exist.

Resulting topology, all on `lms-login.psi.ch`:

```
        your laptop
             │  ssh -L 8000:127.0.0.1:8000 -L 8080:127.0.0.1:8080 thor
             ▼
     ┌───────────────────────── lms-login.psi.ch ─────────────────────────┐
     │                                                                    │
     │  127.0.0.1:8000 ──► firecrest-api  ─┐                              │
     │  127.0.0.1:8080 ──► keycloak       ─┘  podman net "firecrest"      │
     │                          │                                         │
     │                          │ SSH as <user>, static key               │
     │                          ▼                                         │
     │                    sshd :22 ──► sbatch / squeue / ls                │
     │                                   │                                │
     └───────────────────────────────────┼─────────────────────────────────┘
                                         ▼
                          Slurm ctld on lms-mgmt ──► thor[1-10]
```

FirecREST reaches Keycloak as `http://keycloak:8080` over the podman network (aardvark DNS resolves container names). It reaches sshd as `lms-login.psi.ch:22`, going back out to the host's own routable address, which avoids depending on `host.containers.internal` semantics.

`KC_HOSTNAME` is set to `http://localhost:8080/auth` so that the token issuer matches what a tunnelled client sees. This mirrors the upstream demo topology.

### Split of responsibility: puppet versus one-time bootstrap

Puppet manages everything that is **not** a secret:

- `/etc/containers/systemd/firecrest.network`
- `/etc/containers/systemd/keycloak.container`
- `/etc/containers/systemd/firecrest-api.container`
- `/etc/firecrest/f7t-api-config.yaml` (contains only `secret_file:` *references*, no secret values)

A one-time root bootstrap on the node creates everything secret-bearing:

- `/etc/firecrest/secrets/*` (SSH private keys, the service account client secret)
- `/etc/firecrest/keycloak-realm.json` (contains client secrets and the pilot user's password)
- the directories themselves, and `/var/lib/firecrest/keycloak`

The reason for the split is deliberate. Hiera secrets on this cluster use eyaml (`ENC[PKCS7,...]`), which requires the encryption tooling to produce; committing placeholder ciphertext would be worse than committing nothing. More importantly, per-user SSH private keys deserve one deliberate handling rather than a copy-paste round trip. Promoting them into eyaml once the ownership question below is settled is a reasonable follow-up.

The ownership question: the FirecREST image runs as `appuser`, UID 5678. Under rootful podman with no user namespace remapping, a bind-mounted host file is read by host UID 5678. So the secrets directory is `chown 5678:5678`, mode `0700`, files mode `0400`. That keeps them unreadable by everyone except root and a UID that has no login on the host. If those files are ever moved into puppet, `files::files` must be given `owner: '5678'` numerically, and that should be verified on the first run.

### Known limitation of the puppet path

Puppet writing a quadlet file does not run `systemctl daemon-reload`, and quadlet only regenerates units on daemon-reload. So a change to a `.container` file lands on disk but does not take effect until someone runs:

```bash
systemctl daemon-reload && systemctl restart firecrest-api
```

The same applies to `f7t-api-config.yaml`, which FirecREST reads once at startup. This is a genuine wart of doing container orchestration through a file-writing module rather than a container-aware puppet module. It is acceptable for a pilot that changes rarely. If FirecREST becomes a service people depend on, the right fix is a puppet module with a proper `notify` relationship to a `service` resource, or moving to the Helm path (see alternatives).

## Activation runbook

Order matters: the bootstrap must run before the first puppet run, otherwise `files::files` fails on the missing parents and produces noisy (though harmless and self-resolving) puppet errors.

1. Run `scripts/firecrest-bootstrap.sh` on `lms-login` as root. It creates the directory tree, generates the per-user SSH keypairs and the service account secret, writes the Keycloak realm and `keycloak.env`, and prints the generated credentials.

   ```bash
   scp scripts/firecrest-bootstrap.sh lms-login.psi.ch:/tmp/
   ssh lms-login.psi.ch 'sudo bash /tmp/firecrest-bootstrap.sh'
   ```

2. Append each pilot user's generated public key to their `authorized_keys`. The script prints them and does not do this itself, since it writes into a user's home directory.

   ```bash
   ssh lms-login.psi.ch 'sudo cat /etc/firecrest/secrets/ssh_key_geiger_j.pub >> ~/.ssh/authorized_keys'
   ```

3. Commit and push the Hiera change in `data-lms`. The Gitea workflow runs `hiera-update`, which refreshes the data on the puppet server; it triggers no agent run.

4. Apply on this node only. Do not use `run-puppet.sh`, which fans out to all twelve nodes: the change is scoped to one FQDN file, so converging the compute nodes buys nothing.

   ```bash
   ssh lms-login.psi.ch 'sudo /opt/puppetlabs/bin/puppet agent -t --noop'   # inspect
   ssh lms-login.psi.ch 'sudo /opt/puppetlabs/bin/puppet agent -t'
   ```

5. Start the services. Puppet writes the quadlets but does not reload systemd or start anything, so nothing is running until here.

   ```bash
   ssh lms-login.psi.ch 'sudo systemctl daemon-reload && sudo systemctl start keycloak'
   # wait until healthy, then
   ssh lms-login.psi.ch 'sudo systemctl start firecrest-api'
   ```

6. Tunnel and smoke-test. The realm maps the cluster username into `sub`, so a token minted by the AiiDA client must show `"sub": "geiger_j"` rather than a service account name.

```bash
ssh -L 8000:127.0.0.1:8000 -L 8080:127.0.0.1:8080 lms-login.psi.ch

TOKEN=$(curl -s -X POST http://localhost:8080/auth/realms/lms/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=firecrest-aiida-geiger_j \
  -d client_secret=<from bootstrap> | jq -r .access_token)

echo $TOKEN | cut -d. -f2 | python3 -c 'import sys,base64,json; s=sys.stdin.read().strip(); print(json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4))))'

curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/status/systems | jq
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/compute/lms/jobs | jq
```

`/docs` on port 8000 serves the Swagger UI.

Rollback is `systemctl stop firecrest-api keycloak` plus reverting the Hiera commit. Nothing in this deployment touches Slurm, BeeGFS, sshd, or any existing service, which is the main reason to be relaxed about trying it.

## Alternatives and the longer-term path

This section exists because the pilot choices above are deliberately the cheapest ones, and several of them are wrong as permanent answers. Each subsection lists what was chosen, what else exists, and what should eventually replace it.

### Identity provider

**Chosen: self-hosted Keycloak, `KC_DB=dev-file`.** One container, an H2 file database, realm imported from JSON at first start.

The honest assessment: `dev-file` and `start-dev` are, as the names say, development settings. Keycloak in this mode does not do clustering, its H2 store is not something to trust with credentials people care about, and you now operate an identity provider (patching, backups, account lifecycle) on top of operating a cluster. For a pilot with two users this is fine. For twenty real users it is a liability.

Alternatives:

- **PSI central OIDC.** Almost certainly the correct destination if PSI runs one. FirecREST then verifies tokens issued by an identity provider somebody else operates, users authenticate with their PSI credentials, and account lifecycle stops being your problem. The work is registering a client and, critically, arranging that a claim in the issued token equals the cluster username. FirecREST reads whichever claim `username_claim` names, so if PSI issues `preferred_username` as, say, an email address, you need either a mapper on the IdP side or a different claim. Migration cost from the pilot is small: change `token_url`, `public_certs`, and `username_claim`, and delete the Keycloak container. Nothing else in the config moves. Worth asking PSI IT about early, precisely because it is cheap to switch to later.
- **Keycloak in production mode** (`start` rather than `start-dev`, backed by PostgreSQL, behind TLS). The middle option if PSI has no central IdP or will not issue a client. Roughly one more container plus a database to back up.
- **No identity provider at all**, covered in detail as Option B above. FirecREST needs a JWKS document and accepts a `file://` URL for it, so a static key file on disk is sufficient. The same mechanism lets an application that already authenticates its own users (one Airflow instance, one JupyterHub) sign its own tokens and hand FirecREST the public half. The burden of "who is this user, really" moves into whoever holds the signing key.

Recommendation, revised on 2026-08-31 after deciding against involving PSI IT: run the static signing key (Option B). Revisit Keycloak when users need to obtain tokens without an admin minting them. PSI's central OIDC, if it exists, remains a cheap swap later since it touches three config keys.

### SSH credentials

**Chosen: `SSHStaticKeys`.** A dedicated keypair per user, private key held by FirecREST, public key in that user's `authorized_keys`.

This does not scale and it is not what you want permanently, for three reasons: every new user is a manual key ceremony; the API holds long-lived credentials that grant full shell access as those users; and revocation means editing `authorized_keys` on the shared home filesystem. With around 50 users on this cluster it stops being viable quickly.

Alternatives:

- **`SSHCA`: a certificate authority service.** FirecREST presents the user's OIDC token to a CA service, which validates it and returns a short-lived SSH certificate whose principal is that username. The cluster's `sshd` is configured with `TrustedUserCAKeys` pointing at the CA public key and trusts any certificate it signed. No per-user keys anywhere, certificates expire in minutes, and revocation is revoking the token. Upstream's demo uses the DeiC `sshca` service (`github.com/wayf-dk/sshca`, pinned to a specific commit in `build/docker/deic-sshca/Dockerfile`, and described upstream as under development). Cost: one more security-critical service to run, plus an `sshd_config.d` drop-in on every node FirecREST talks to. The CA private key is the crown jewel: anyone holding it can become any user on the cluster.
- **`SSHService`: a generic key service.** Same shape as `SSHCA` but a different response contract, for sites that already run their own key-issuing service. Not relevant here unless PSI has one.

Note that both certificate options interact well with the `ForceCommand` wrapper pattern documented for v1: an `sshd` `ForceCommand` script can log and whitelist every command arriving over a FirecREST certificate, which is worth doing if this ever faces more than pilot users.

Recommendation: treat static keys as valid only while the pilot is two or three people who already have full shell access anyway, so the keys grant nothing they do not already have. Before onboarding anyone else, move to `SSHCA`. That migration also wants the `sshd_config.d` drop-in to be puppet-managed and rolled out to `lms-login` (and to any other node FirecREST is pointed at), which is squarely in scope for this Hiera repo.

### Data transfer

**Chosen: none.** `data_operation.data_transfer` is left unset, so uploads and downloads stream through the API and are capped at `max_ops_file_size` (5 MB).

For a cluster where users already have SSH and can `scp`, this is a reasonable permanent answer. FirecREST's large-transfer machinery exists because CSCS users often cannot reach the cluster directly at all.

Alternatives, in the order they make sense here:

- **S3 (`service_type: s3`).** The mainstream option. FirecREST stages data in an object store and hands the client a presigned URL, so bulk bytes never traverse the API. Needs an S3-compatible endpoint: MinIO as a third container, or an institutional S3 if PSI offers one. Large transfers additionally run as Slurm jobs (`datatransfer_jobs_directives` controls the flags), so a dedicated transfer partition is the usual refinement; on this cluster the `short` partition is the natural target.
- **Streamer (`service_type: streamer`).** A direct socket stream between client and cluster over a configured port range, no object store. Fewer moving parts than S3 but it needs open inbound ports, which cuts against the loopback-only posture.
- **Wormhole (`service_type: wormhole`).** Magic-wormhole style rendezvous transfer. Used in the upstream demo for the PBS cluster. Least conventional of the three.

Recommendation: leave it unset. Revisit only if a concrete workload needs to push large inputs through the API rather than over `scp` or from `/scratch`. If it does, S3 with MinIO on `/scratch` is the obvious shape.

### How FirecREST talks to Slurm

**Chosen: `connection_mode: ssh`.** FirecREST SSHes in and runs `sbatch`, `squeue`, `scancel`, parsing the output. Works against Slurm 25.11.7 today with zero cluster-side change.

Alternatives:

- **`rest`**: talk to `slurmrestd` over HTTP with Slurm's JWT auth. Faster and structurally parsed rather than screen-scraped, and it removes one SSH round trip per scheduler call. Requires enabling `slurmrestd` (currently inactive), configuring `auth/jwt`, and pinning the API version (upstream's demo uses `0.0.42`). Slurm's REST API versions churn between releases, which is real ongoing maintenance.
- **`hybrid`**: scheduler calls over REST, everything else over SSH.

Recommendation: stay on `ssh`, and note this is now a hard constraint rather than a preference. `aiida-firecrest` submits jobs by `script_remote_path`, which FirecREST only honours in SSH mode, since slurmrestd takes the script inline. Against a `rest`-mode system every submission returns 501 and the calcjob pauses after five retries (verified 2026-09-01 against the upstream demo stack; reported to `aiida-firecrest`). So moving to `rest` would break AiiDA on this cluster entirely until the plugin chooses the parameter based on `scheduler.connectionMode`. The version-pinning maintenance argument stands on top of that.

### Deployment mechanism

**Chosen: podman quadlets written by `files::files`.** Declarative in Hiera, no new puppet module, and it produces genuine systemd units.

Alternatives:

- **Kubernetes plus the upstream Helm chart** (`helm repo add firecrest-v2 https://eth-cscs.github.io/firecrest-v2/charts/`). This is the only path upstream documents, so it gets upstream's testing and its config surface is exercised. It is also the wrong tool for a ten-node bare-metal Slurm cluster with no existing Kubernetes. Only sensible if PSI already runs a cluster you can deploy into, in which case FirecREST does not need to live on `lms-login` at all: it only needs network reach to `sshd` and Slurm.
- **A proper puppet container module** (`puppetlabs-podman` or similar), which would give real `notify`/`subscribe` between config files and the service and eliminate the manual `daemon-reload`. The clean answer within the current architecture, gated on whether PSI's puppet environment makes such a module available.
- **Native, no container**: a Python 3.12 virtualenv plus a hand-written systemd unit. Removes the image-pull and `/var` space questions. Adds the burden of managing a Python 3.12 runtime on RHEL 8.10, which ships 3.6 as system Python. Not worth it.

Recommendation: quadlets now. If this graduates from pilot to a service people depend on, the manual `daemon-reload` is the first thing to fix, via a container-aware puppet module.

### Network exposure and TLS

**Chosen: loopback only, reached over an SSH tunnel.**

This is the right call for a pilot and the wrong one for anything else, since the whole point of FirecREST is to be reachable by clients that cannot SSH. Note that `firewalld` is inactive on this host, so "publish on `0.0.0.0`" means "reachable from wherever PSI's network permits", with no second line of defence. Publishing plaintext HTTP with bearer tokens on it would put credentials on the wire.

The progression, in order:

1. Loopback plus tunnel (now).
2. A TLS-terminating reverse proxy on the host (nginx or Caddy as a third quadlet) with a PSI-issued certificate, publishing 443. FirecREST's `apis_root_path` exists for exactly this case when the API is served under a path prefix.
3. A PSI-managed gateway in front, if one exists, which is also where rate limiting and per-route access control belong.

Keycloak needs the same treatment on the same schedule, and arguably first: an identity provider on plaintext HTTP is worse than an API on plaintext HTTP.

### Authorization

**Chosen: none.** Any user with a valid token can call any endpoint. What actually stops them doing damage is that FirecREST acts as *them*, so POSIX permissions and Slurm accounting apply exactly as they do over SSH.

For this cluster that is a defensible permanent position: FirecREST grants no privilege that the user did not already have with a shell.

The alternative is **OpenFGA** (`auth.authorization`), a relationship-based authorization service, which lets you express rules like "these users may use this system" or "this client may only read". It matters at a site with many systems and clients of differing trust. Here it would be machinery without a corresponding problem, at least until FirecREST is exposed to clients that are not the users themselves.

### Consuming it from AiiDA

The reason this is interesting at all: `aiida-firecrest` (cloned at
`~/aiida_projects/firecrest/git-repos/aiida-firecrest`) is an AiiDA transport plugin that speaks FirecREST
instead of SSH, and `pyfirecrest` is the Python client.

**Checked on 2026-09-01, and it works.** `aiida-firecrest` 1.0.0 imports `from firecrest.v2 import ...`, so it
targets v2. Against the upstream containerised demo stack running FirecREST 2.6.0, `verdi computer test` passed
all six checks and a `MultiplyAddWorkChain` ran to completion, including with the server switched to `SSHCA`
credentials, so the certificate path is exercised too. Three consequences for this deployment:

- The `connection_mode: "ssh"` chosen above is required, not merely preferred. See the scheduler section.
- FirecREST restricts filesystem operations to the paths in `file_systems`, here `/mnt/home` and `/scratch`. A
  code whose `filepath_executable` is an absolute path outside those (`/bin/bash`, say) fails `verdi code test`
  with the misleading message "Could not connect to the configured computer", because aiida-core replaces the
  server's 400 with a generic one. Use a relative executable and AiiDA skips the check by design.
- `aiida-firecrest` requires a `billing_account` and a `temp_directory`; the latter must sit under a configured
  filesystem, so `/mnt/home/<user>/tmp` rather than `/tmp`.

The pinned image can also move from 2.5.6 to 2.6.0: that release has API-breaking changes (UserInfo response
refactor, job listing defaulting to a 24h lookback) but it is the version the plugin was just tested against.

## Open questions

- Should the staged Hiera be reshaped from Option C (Keycloak) to Option B (static signing key)? Recommended, not yet done.
- Is a PSI-issued TLS certificate obtainable for `lms-login.psi.ch`? Needed before any non-loopback exposure.
- Does `files::files` accept a numeric `owner`? Only matters if secrets are later promoted into eyaml.

## References

- v2 docs: <https://eth-cscs.github.io/firecrest-v2/>, configuration reference at `/setup/conf/`
- v2 source: <https://github.com/eth-cscs/firecrest-v2>, cloned at `~/aiida_projects/firecrest/git-repos/firecrest-v2`
- Config model (authoritative over the docs): `src/firecrest/config.py`
- Reference config: `f7t-api-config.local-env.yaml`, and `build/helm/firecrest-api/values.yaml` for the annotated version
- v1 source (not used): <https://github.com/eth-cscs/firecrest>
- Container background on this cluster: `hpc-admin/docs/containers-architecture.md`
