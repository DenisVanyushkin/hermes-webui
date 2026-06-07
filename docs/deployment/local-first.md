# Hermes WebUI local-first deployment

This branch prepares a local-first, host-run admin console for Hermes without changing the existing host layout.

## Source of truth

- Fork: `https://github.com/DenisVanyushkin/hermes-webui`
- Upstream: `https://github.com/nesquena/hermes-webui`
- Default branch for the local deployment flow: feature branch `feature/local-first-admin-console`

## Principles

- No GitHub Actions.
- No external Docker registry.
- No production deploy until explicitly approved.
- No host-path migration by default.
- Cloudflare Access / cloudflared is handled outside this repo.
- WebUI publishes only on `127.0.0.1:8787` on the host side.

## Local-first flow

1. `deploy/build.sh`
   - builds `hermes-webui:<git-sha>` locally
   - verifies Hindsight policy
   - verifies `hindsight-client` is absent when `ENABLE_HINDSIGHT=false`
2. `deploy/deploy.sh`
   - tags current image as `previous`
   - tags the new SHA image as `prod`
   - starts compose without rebuilding
   - runs smoke
3. `deploy/smoke.sh`
   - checks `http://127.0.0.1:8787/health`
   - verifies Hindsight stays absent in default mode
4. `deploy/rollback.sh`
   - restores the previous image tag
   - restarts compose
   - re-runs smoke
5. `deploy/status.sh`
   - prints release history, audit tail, container status
6. `deploy/sync-upstream.sh`
   - fetches upstream
   - reports drift
   - does not deploy

## Agent path resolution

- The Hermes Agent source is taken from the mounted `HERMES_HOME` volume by
  default, not from a separate `/opt/hermes-admin/repos/hermes-agent` tree.
- In the normal production setup, the agent path inside the container resolves
  to `/opt/hermes-admin/hermes-home/hermes-agent`.
- The temporary symlink workaround is not required for the standard deployment
  path.

## Python interpreter resolution

- WebUI already supports `HERMES_WEBUI_PYTHON` as the explicit override for the
  interpreter it launches and uses for agent imports.
- In production, point it at the real agent venv, not the local `.venv` that
  belongs to the WebUI checkout.
- Recommended default for this host layout:
  `/opt/hermes-admin/hermes-home/hermes-agent/venv/bin/python`
- The local-first compose file and `.env.example` set that value so the WebUI
  does not auto-detect the broken `.venv/bin/python` path.

## Port

- Default host publish: `127.0.0.1:8787:8787`
- Tunnel target for cloudflared: `http://127.0.0.1:8787`
- If 8787 is occupied, choose the nearest free port and update `HERMES_WEBUI_PORT` consistently in `.env` and compose.

## Default Hindsight policy

- `ENABLE_HINDSIGHT=false`
- `hindsight-client` must not be installed in the default mode
- if `ENABLE_HINDSIGHT` is later approved, use the fallback policy in `hindsight-policy.md`

## Host-side release metadata

- `current`
- `previous`
- `history.log`
- audit log
- backups before sensitive writes
