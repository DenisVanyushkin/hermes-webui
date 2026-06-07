# Host-side deploy gateway blueprint

This directory describes the host-side control plane for `hermes-webui`.

## What changed in the model

The gateway no longer calls mutable repo scripts directly.
Instead:

1. The repo keeps the source version of the control scripts.
2. A root-only install step copies approved scripts into
   `/usr/local/lib/hermes-webui-control/`.
3. The wrapper at `/usr/local/sbin/hermes-webui-control` only executes the
   installed root-owned scripts.
4. Updating those installed scripts is a separate explicit root action with
   approval. It is *not* done by WebUI at runtime.

## Immutable control-plane files

Installed on the host by `deploy/host-gateway/install.sh`:

- `/usr/local/sbin/hermes-webui-control`
- `/usr/local/lib/hermes-webui-control/lib.sh`
- `/usr/local/lib/hermes-webui-control/build`
- `/usr/local/lib/hermes-webui-control/deploy`
- `/usr/local/lib/hermes-webui-control/rollback`
- `/usr/local/lib/hermes-webui-control/smoke`
- `/usr/local/lib/hermes-webui-control/status`
- `/usr/local/lib/hermes-webui-control/approved-branch`
- `/usr/local/lib/hermes-webui-control/approved-releases.tsv`
- `/usr/local/share/doc/hermes-webui-control/authorized_keys.example`
- `/usr/local/share/doc/hermes-webui-control/sudoers.example`
- `/opt/hermes-webui/ssh` — host-side persistent SSH control path used by the
  gateway, the WebUI container, and per-dialog Hermes sandboxes

## Mutable source files

These stay in the repo and are *not* used directly by the gateway at runtime:

- `deploy/build.sh`
- `deploy/deploy.sh`
- `deploy/rollback.sh`
- `deploy/smoke.sh`
- `deploy/status.sh`
- `deploy/lib.sh`
- `deploy/host-gateway/hermes-webui-control`
- `deploy/host-gateway/install.sh`

## Target properties

- No `docker.sock` inside the WebUI container or sandbox.
- The host gateway runs as the `hermes` user and does not need a container
  mount for `/opt/hermes-webui/ssh`.
- No unrestricted shell for the deploy user.
- No sudo access to mutable repo scripts.
- One root-owned wrapper at `/usr/local/sbin/hermes-webui-control`.
- Allowed actions only:
  - `status`
  - `build <sha>`
  - `deploy <sha>`
  - `smoke`
  - `rollback`
- Wrapper audits every invocation.
- Wrapper writes per-operation logs under `/opt/hermes-webui/audit/ops/`.
- Deploy is blocked unless compose/security policy passes.
- SSH access is restricted by `authorized_keys` forced-command.
- Build/deploy/rollback/smoke use a lock file so they cannot run concurrently.

## Execution model

### Preferred operator path

- SSH key lands on a dedicated deploy account with no normal shell.
- The account does **not** get sudo on repo scripts.
- The account does **not** need `docker` group membership if you can instead
  expose only the root-owned gateway wrapper through a narrowly scoped sudo
  rule.

### Important Docker note

If the deploy user is put into the `docker` group, treat that as
**root-equivalent capability**.
That is the cheap path, but it is not the nice one.
Prefer a root-owned wrapper plus a tightly scoped privileged entrypoint.

## Security model

- The wrapper is root-owned and executed via forced-command.
- The SSH control directory is mounted read-only into the WebUI container and
  into Hermes per-dialog sandboxes; it stays writable only on the host side.
- The deploy user should ideally use `nologin`.
- The user does not get an interactive shell.
- The user does not get sudo on the repo checkout or deploy scripts.
- The wrapper only calls installed scripts under
  `/usr/local/lib/hermes-webui-control/`.
- The wrapper validates the local compose/security policy before build/deploy.
- The wrapper checks that the target SHA is a real commit object.
- The wrapper checks that the repo checkout is clean.
- The wrapper only allows deployment from:
  - the approved branch recorded in
    `/usr/local/lib/hermes-webui-control/approved-branch`, or
  - approved release metadata in
    `/usr/local/lib/hermes-webui-control/approved-releases.tsv`
- The wrapper appends to `/opt/hermes-webui/audit/host-gateway.log` and
  per-operation logs in `/opt/hermes-webui/audit/ops/`.

## Command flow

### `status`
- read-only
- no lock
- no write actions
- only reads installed status + release state

### `build <sha>`
- acquire lock
- validate compose/security policy
- verify installed scripts are root-owned and immutable
- verify repo checkout is clean
- verify `<sha>` is a commit object
- verify `<sha>` matches checked-out `HEAD`
- verify approval source
- run installed `build`

### `deploy <sha>`
- acquire lock
- same checks as `build`
- run installed `deploy`

### `smoke`
- acquire lock
- validate compose/security policy
- run installed `smoke`

### `rollback`
- acquire lock
- validate compose/security policy
- verify repo checkout is clean
- run installed `rollback`

## Expected host layout

- Repo checkout: `/opt/hermes-webui/repo`
- Persistent SSH control path: `/opt/hermes-webui/ssh`
- Release state: `/opt/hermes-webui/releases`
- Backups: `/opt/hermes-webui/backups`
- Audit: `/opt/hermes-webui/audit`
- Logs: `/opt/hermes-webui/logs`

Existing Hermes state stays where it already is.
`/opt/hermes-admin/...` remains a container-side namespace via bind mounts.

## Ownership / mode matrix

### Installed root-owned immutable files

- `/usr/local/sbin/hermes-webui-control` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/lib.sh` — `root:root`, `0644`
- `/usr/local/lib/hermes-webui-control/build` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/deploy` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/rollback` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/smoke` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/status` — `root:root`, `0755`
- `/usr/local/lib/hermes-webui-control/approved-branch` — `root:root`, `0644`
- `/usr/local/lib/hermes-webui-control/approved-releases.tsv` — `root:root`, `0644`
- `/usr/local/share/doc/hermes-webui-control/authorized_keys.example` —
  `root:root`, `0644`

### Host data directories

- `/opt/hermes-webui/audit` — root-owned, writable by the gateway
- `/opt/hermes-webui/audit/ops` — root-owned, writable by the gateway
- `/opt/hermes-webui/backups` — root-owned, writable by the gateway
- `/opt/hermes-webui/logs` — root-owned, writable by the gateway
- `/opt/hermes-webui/releases` — root-owned, writable by the gateway

### Mutable files

The following remain mutable only as source in the repo and are **not** the
runtime control plane:

- `deploy/*.sh`
- `deploy/lib.sh`
- `deploy/host-gateway/*.sh`
- `deploy/host-gateway/*.md`

## How to update control scripts

1. Change the source scripts in the repo.
2. Review and approve the change.
3. Run `deploy/host-gateway/install.sh` as root.
4. Verify the installed files under `/usr/local/lib/hermes-webui-control/`.
5. Only then use the gateway again.

## Remaining risks

- If the deploy user is placed in `docker`, that is effectively root-equivalent.
- If the repo checkout itself is writable by someone untrusted, builds still
  depend on the clean-checkout gate and approved-source gate, but the host
  should still keep the checkout tightly controlled.
- The gateway does not by itself solve Cloudflare Access or SSH distribution.
  It only hardens the host-side execution path.
- If the sandbox config is not updated, the per-dialog containers still will not
  see `/opt/hermes-webui/ssh` even if the host gateway works fine.

## Hermes sandbox mounts

Per-dialog Hermes containers do **not** get mounts from the WebUI compose file.
Their filesystem mounts come from `terminal.docker_volumes` in
`/home/hermes/.hermes/config.yaml` (or the active profile equivalent).

For the SSH control path, the proposed sandbox mount is:

```yaml
terminal:
  docker_volumes:
    - /opt/hermes-webui/ssh:/opt/hermes-webui/ssh:ro
```

Notes:
- keep it read-only
- do not mount `docker.sock`
- do not mount Cloudflare secrets or registry tokens
- do not change the gateway wrapper path; deploy still goes through
  `/usr/local/sbin/hermes-webui-control`

## Access is not enabled yet

This blueprint does **not** install the wrapper, create the SSH key, or change
service accounts.
Those steps are intentionally deferred until you explicitly ask to enable
access on the real host.

For a concrete step-by-step runbook, see:

- `docs/deployment/host-bootstrap-checklist.md`
