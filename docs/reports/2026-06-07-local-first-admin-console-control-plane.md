# Local-first Hermes WebUI Admin Console / host-gateway control plane

_Date: 2026-06-07_

## 1. Executive summary

We built and verified a local-first Hermes WebUI admin console backed by a host-side gateway control plane.

What it does:
- lets the WebUI, the host, and per-dialog Hermes sandboxes control the host gateway through the same SSH command path
- exposes only a narrow set of control actions: `status`, `smoke`, `build <sha>`, `deploy <sha>`, and `rollback`
- keeps the WebUI published only on loopback on the host
- keeps the SSH control path mounted read-only into the WebUI container and Hermes sandboxes

Current verified state:
- `current-release: efbb52019a78`
- `previous-release: a44cf1c4c844`
- `release-drift: no`
- WebUI container: healthy
- WebUI health: OK
- host forced-command SSH gateway: OK
- WebUI container access to gateway: OK
- Hermes per-dialog sandbox access to gateway: OK
- deploy smoke: OK
- hindsight policy: `ENABLE_HINDSIGHT=false`
- `hindsight-client` package: absent
- `docker.sock` is not mounted into the WebUI or sandbox control path

Why it matters:
- operators get one reproducible control plane instead of a pile of ad-hoc shell access
- release metadata now tracks reality instead of drifting ahead of it
- the WebUI can verify and operate the host gateway without getting full host access
- the sandbox path stays read-only and narrowly scoped, which keeps the blast radius sane

## 2. Architecture

### Host gateway

The actual host gateway runs on the host.

It exposes the approved control actions:
- `status`
- `smoke`
- `build <sha>`
- `deploy <sha>`
- `rollback`

### Forced-command SSH

Access is via a dedicated forced-command SSH user:
- `hermes-webui-deploy`

The SSH control command path that works from every environment is:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

### WebUI container

The WebUI container gets read-only access to the SSH control path via compose:

```yaml
${HOST_WEBUI_CONTROL_SSH:-/opt/hermes-webui/ssh}:/opt/hermes-webui/ssh:ro
```

The container binds the UI only to host loopback:
- `127.0.0.1:8787`

### Hermes per-dialog sandbox

Per-dialog Hermes sandboxes also receive the SSH control path as a read-only mount:
- `/opt/hermes-webui/ssh:/opt/hermes-webui/ssh:ro`

That gives sandbox sessions the same control command path without granting broader host access.

### Repo mount

The WebUI repo is mounted into the sandbox as:
- `/opt/hermes-webui/repo:/workspace/hermes-webui:rw`

### SSH control path mount

The SSH client config/key path is:
- `/opt/hermes-webui/ssh`

The private key is mounted read-only into the WebUI container and into per-dialog Hermes sandboxes.

The SSH config currently uses:
- `HostName 172.17.0.1`

Reason:
- `host.docker.internal` did not resolve in the Hermes sandbox even after `docker_extra_args`, so the gateway target was pinned to the Docker host bridge address.

### Release metadata files

Release state is tracked in metadata and audit history under the host control plane.

The important behavior now is:
- deploy and rollback do **not** write `releases/current` and `releases/previous` before smoke passes
- metadata is updated only after successful smoke
- `status` compares metadata against the actual running release from the `/health` `Server` header
- if drift is detected, `status` prints:
  - `release-drift: yes`
  - `repair-command: HERMES_WEBUI_REPAIR_METADATA=1 bash deploy/status.sh`

Metadata repair was verified and used successfully.

### Audit / release history

The control plane keeps audit and release history so operators can inspect what happened without guessing.

The verified status output includes:
- compose status
- release history tail
- audit tail

## 3. Security boundaries

This control path is intentionally narrow.

- No `docker.sock` mount
- Forced-command only
- Narrow sudoers rule / narrow privileged entrypoint only
- Read-only SSH key mount
- No unrestricted shell through this control path
- `ENABLE_HINDSIGHT=false`
- No `hindsight-client` installed
- WebUI binds to `127.0.0.1` on host

The host-gateway path is for the approved commands only, not for general host login.

## 4. Operational commands

### Host

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

### WebUI container

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.local-first.yml exec hermes-webui \
  ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
```

### Hermes sandbox

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

### Deploy flow

```bash
cd /workspace/hermes-webui
git fetch origin
git checkout feature/local-first-admin-console
git pull --ff-only origin feature/local-first-admin-console
SHA="$(git rev-parse --short=12 HEAD)"
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control build "$SHA"
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control deploy "$SHA"
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
```

### Rollback

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control rollback
```

### Metadata repair

```bash
HERMES_WEBUI_REPAIR_METADATA=1 bash deploy/status.sh
```

## 5. Verification evidence

Verified final facts:
- `current-release: efbb52019a78`
- `previous-release: a44cf1c4c844`
- `release-drift: no`
- `deploy-applied` event exists for `efbb52019a78`
- host control status: OK
- WebUI container control status: OK
- Hermes sandbox control status: OK
- smoke: OK

The host-side status output also showed:
- `deploy-hermes-webui-1` is `Up ... (healthy)`
- the release history contains `deploy-applied | current=efbb52019a78 previous=a44cf1c4c844`

## 6. Known caveats

- Cold start can take several minutes because runtime `/app/venv` installs WebUI and Hermes agent base deps.
- Existing persistent sandbox containers do not receive new mounts or docker flags; they must be removed and recreated.
- `host.docker.internal` did not resolve in the sandbox; the current working config uses `172.17.0.1`.
- `curl -I /health` may return `501` because `HEAD` is not supported; use `GET` or `curl -fsS` instead.

## 7. Troubleshooting

### `release-drift: yes`

Run metadata repair only if the running container is healthy:

```bash
HERMES_WEBUI_REPAIR_METADATA=1 bash deploy/status.sh
```

### SSH config not found

Check that `/opt/hermes-webui/ssh` is mounted into the environment you are using.

### SSH connection refused to `127.0.0.1`

The SSH config is wrong inside the container or sandbox. It should not point to container localhost.

### `host.docker.internal` not resolving

Use `172.17.0.1` for the current setup, or fix the Docker extra-hosts path if you want to restore the name-based route.

### Deploy timeout

Inspect logs before rebooting or redeploying. The smoke path can take time during the cold-start dependency install window.

### Persistent sandbox is stale

Remove and recreate the old sandbox containers, then restart the gateway.

### Mount missing after gateway restart

If the mount is still absent, verify the sandbox/container was recreated after the restart. Existing containers do not gain new mounts.

## 8. Next recommended improvements

- Move runtime dependency install out of the cold startup path or cache it.
- Investigate why `terminal.docker_extra_args` did not apply `host.docker.internal`.
- Add a first-class Hermes command/runbook for WebUI deploy.
- Add periodic control-plane self-check.
- Add a docs link from README / local-first deployment docs.

## Appendix: concise operator note

This stack is now a local-first WebUI control plane with host-side execution, narrow SSH-based control, read-only mounts into WebUI and Hermes sandboxes, and verified healthy release state.

The clean operator surface is:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```
