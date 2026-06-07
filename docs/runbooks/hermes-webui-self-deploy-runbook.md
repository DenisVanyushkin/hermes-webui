# Hermes WebUI Self-Deploy Runbook

This runbook is for *Hermes / the Coding Agent*.

Use it when you need to safely deploy Hermes WebUI through the host-gateway control plane.

## 1. Scope

You may do only these control actions through the host gateway:

- `status`
- `smoke`
- `build <sha>`
- `deploy <sha>`
- `rollback`

You must **not** do these things unless a human explicitly approves a separate change:

- touch `docker.sock`
- change `sudoers`
- change SSH key material or SSH config
- reboot the host
- deploy from a dirty checkout
- deploy from a branch other than the approved branch
- enable `ENABLE_HINDSIGHT=true`
- install `hindsight-client` when `ENABLE_HINDSIGHT=false`
- widen secret mounts or expose extra host paths
- bypass the forced-command SSH control path

## 2. Control plane

All control-plane actions go through this entrypoint:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control <action>
```

Paths and identities:

- SSH config path: `/opt/hermes-webui/ssh/config`
- SSH control directory: `/opt/hermes-webui/ssh`
- deploy repo path in sandbox: `/workspace/hermes-webui`
- deploy repo path on host: `/opt/hermes-webui/repo`
- forced-command SSH user on the host gateway: `hermes-webui-deploy`

Allowed wrapper actions:

- `status`
- `smoke`
- `build`
- `deploy`
- `rollback`

The wrapper is responsible for:

- checking immutable installed scripts
- checking approved branch / approved release policy
- checking that the repo checkout is clean
- checking security policy before build/deploy/rollback/smoke
- writing audit logs
- taking a lock for `build` / `deploy` / `rollback` / `smoke`

The SSH control path is mounted read-only into the WebUI container and into Hermes per-dialog sandboxes. Do not widen that mount.

## 3. Pre-flight checklist

Run this before any deploy decision:

```bash
cd /workspace/hermes-webui

git status --short
git branch --show-current
git log --oneline -5

ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

Expected result:

- `git status` is clean
- branch is `feature/local-first-admin-console`
- `status` shows a healthy WebUI
- `release-drift: no`
- `smoke` already passed

If `release-drift: yes`:

- do **not** deploy immediately
- first inspect `current-release`, `previous-release`, and the running release from `status`
- if the running container is healthy, you may use the documented metadata-repair path
- if anything looks weird, stop and ask a human for approval

## 4. Normal deploy flow

Use this flow exactly:

```bash
cd /workspace/hermes-webui
git fetch origin
git checkout feature/local-first-admin-console
git pull --ff-only origin feature/local-first-admin-console

git status --short
SHA="$(git rev-parse --short=12 HEAD)"

ssh -F /opt/hermes-webui/ssh/config hermes-webui-control build "$SHA"
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control deploy "$SHA"
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
```

Expected successful result:

- deploy completed
- smoke passed for `$SHA`
- `current-release = $SHA`
- `running-release = $SHA`
- `release-drift: no`
- WebUI is healthy

## 5. Post-deploy verification

After deploy, verify the live health endpoint with GET, not HEAD:

```bash
curl -fsS http://127.0.0.1:8787/health
```

Important caveat:

- `curl -I /health` may return `501` because `HEAD` is not supported
- use `curl -fsS http://127.0.0.1:8787/health`

Also re-check:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

Record in your report:

- deployed SHA
- `current-release`
- `previous-release`
- `running-release`
- `release-drift` status
- smoke result
- health result

## 6. Rollback flow

Safe rollback is:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control rollback
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control smoke
```

Expected result:

- rollback completes
- `current-release` becomes the previous healthy release
- `release-drift: no`
- WebUI stays healthy

If rollback smoke times out:

- do **not** reboot the host
- do **not** blindly run deploy again
- first inspect:

```bash
ssh -F /opt/hermes-webui/ssh/config hermes-webui-control status
curl -fsS http://127.0.0.1:8787/health
docker compose --env-file deploy/.env -f deploy/docker-compose.local-first.yml logs --tail=260 hermes-webui
```

If the container is healthy, then check release drift and use the metadata repair path if appropriate.

## 7. Metadata drift handling

`status.sh` compares metadata to the actual running release from the `/health` `Server` header.

If `current-release != running-release`, `status` will show:

- `release-drift: yes`
- `repair-command: HERMES_WEBUI_REPAIR_METADATA=1 bash deploy/status.sh`

Rule for Hermes:

- do **not** repair metadata through arbitrary host shell access
- repair is not a separate forced-command action yet
- if drift appears, collect evidence first
- verify health first
- propose a human-approved repair
- or open a PR for a dedicated safe wrapper action such as `repair-metadata`

Known local command for a human operator:

```bash
HERMES_WEBUI_REPAIR_METADATA=1 bash deploy/status.sh
```

## 8. Cold start and smoke budget

Cold start is slow. Expect it.

Why:

- WebUI cold start can take 2–4+ minutes
- runtime `/app/venv` is created on startup
- WebUI base deps and Hermes agent base deps are installed during startup

Smoke timeout behavior:

- `smoke.sh` waits dynamically
- the readiness budget is `max(600s, healthcheck.start_period + 300s)`
- if `HERMES_WEBUI_SMOKE_TIMEOUT_SECONDS` is set, that can override the default budget

Transient startup errors are normal:

- `connection reset by peer`
- `empty reply from server`
- `connection refused`

Do **not** treat those as deploy failure until the readiness timeout is actually exhausted.

## 9. Security guardrails

Hard rules:

- do not add a `docker.sock` mount
- do not expand `sudoers`
- do not remove forced-command SSH
- do not make the SSH key writable inside containers
- do not change `/opt/hermes-webui/ssh` without approval
- do not deploy from a dirty checkout
- do not change `ENABLE_HINDSIGHT=true` without approval
- do not install `hindsight-client` when `ENABLE_HINDSIGHT=false`
- do not open WebUI directly to the network; host bind stays `127.0.0.1:8787`
- do not use reboot as a deploy fix

## 10. Troubleshooting

### SSH config not found

Check:

```bash
ls -la /opt/hermes-webui/ssh
```

Likely cause:

- the mount is missing in the sandbox or WebUI container

### SSH connection refused to `127.0.0.1`

Cause:

- the SSH config is pointing at container localhost

Fix:

- the working `HostName` for this setup is `172.17.0.1`

### `host.docker.internal` does not resolve

Known caveat:

- `terminal.docker_extra_args` with `--add-host` did not work in the sandbox path
- current fallback is `172.17.0.1`

### Persistent sandbox does not see new mount

Cause:

- Docker does not add mounts to an already-created container

Fix:

- remove the old `hermes-*` sandbox container
- restart the gateway
- create a fresh sandbox

### Deploy timeout

Rule:

- inspect logs, status, and health first
- do not reboot
- do not blindly rerun deploy

### `release-drift: yes`

Rule:

- gather `current-release`, `previous-release`, `running-release`, and health
- repair only if the runtime is healthy
- preferably use the approved wrapper action if one exists
- otherwise ask a human for approval before doing the local metadata repair command

## 11. Reporting template

Use this after deploy or rollback.

```text
Deployment report:
- repo:
- branch:
- target SHA:
- build result:
- deploy result:
- smoke result:
- current-release:
- previous-release:
- running-release:
- release-drift:
- health:
- rollback available:
- audit entries:
- issues:
- next action:
```
