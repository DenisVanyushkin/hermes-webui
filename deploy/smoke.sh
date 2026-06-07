#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_cmd docker
require_cmd curl

port="${HERMES_WEBUI_PORT:-8787}"
sha="${1:-$(release_state_current)}"
service_name="hermes-webui"
health_url="http://127.0.0.1:${port}/health"
ready_timeout_seconds="${HERMES_WEBUI_SMOKE_TIMEOUT_SECONDS:-180}"
ready_interval_seconds=2

container_id="$(docker compose -f "$(compose_file_path)" ps -q "$service_name" 2>/dev/null || true)"
[ -n "$container_id" ] || die "compose service $service_name is not running"

wait_for_health() {
  local deadline now code stderr health_status
  deadline="$(( $(date +%s) + ready_timeout_seconds ))"
  while :; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      break
    fi

    health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || echo unknown)"
    if [ "$health_status" = 'unhealthy' ]; then
      log "container healthcheck reports unhealthy; waiting for /health to recover"
    fi

    stderr_file="$(mktemp)"
    if code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 5 "$health_url" 2>"$stderr_file")"; then
      rm -f "$stderr_file"
      if [ "$code" = '200' ]; then
        return 0
      fi
      log "health endpoint returned HTTP ${code}; waiting for 200"
    else
      stderr="$(tr '\n' ' ' < "$stderr_file" | sed 's/[[:space:]]\+/ /g')"
      rm -f "$stderr_file"
      case "$stderr" in
        *'Connection reset by peer'*|*'Empty reply from server'*|*'Failed to connect'*|*'Connection refused'*|*'timed out'*|*'Operation timed out'*|*'Recv failure'* )
          log "health endpoint not ready yet: ${stderr:-curl transient error}"
          ;;
        *)
          die "health probe failed unexpectedly: ${stderr:-curl error}"
          ;;
      esac
    fi

    sleep "$ready_interval_seconds"
  done

  die "health endpoint did not return HTTP 200 at ${health_url} within ${ready_timeout_seconds}s"
}

wait_for_health

logs="$(docker logs "$container_id" --tail 200 2>/dev/null || true)"
if ! is_true "${ENABLE_HINDSIGHT:-false}"; then
  if printf '%s\n' "$logs" | grep -Fqi 'hindsight-client'; then
    while IFS= read -r bad_signal; do
      [ -n "$bad_signal" ] || continue
      if printf '%s\n' "$logs" | grep -Fq "$bad_signal"; then
        die "startup logs show an actual hindsight install/policy failure: $bad_signal"
      fi
    done <<'EOF'
ENABLE_HINDSIGHT=true; installing
Failed to install hindsight-client
ENABLE_HINDSIGHT=false but hindsight-client is already installed
hindsight-client unexpectedly installed
ENABLE_HINDSIGHT=true requires hindsight-client==0.7.2
EOF
  fi
  docker exec "$container_id" /app/venv/bin/python - <<'PY'
import importlib
import importlib.metadata as metadata
import sys

for module in ('dotenv', 'requests', 'httpx', 'run_agent', 'hermes_cli'):
    importlib.import_module(module)

if not sys.executable.startswith('/app/venv/bin/python'):
    raise SystemExit(f'unexpected runtime python: {sys.executable}')

try:
    version = metadata.version('hindsight-client')
except metadata.PackageNotFoundError:
    print('absent')
else:
    raise SystemExit(f'unexpected hindsight-client installed: {version}')
PY
else
  docker exec "$container_id" /app/venv/bin/python - <<'PY'
import importlib
import importlib.metadata as metadata
import sys

for module in ('dotenv', 'requests', 'httpx', 'run_agent', 'hermes_cli'):
    importlib.import_module(module)

if not sys.executable.startswith('/app/venv/bin/python'):
    raise SystemExit(f'unexpected runtime python: {sys.executable}')

version = metadata.version('hindsight-client')
assert version == '0.7.2', version
print(version)
PY
fi

record_audit "smoke" "sha=${sha} port=${port} hindsight=${ENABLE_HINDSIGHT:-false}"
log "smoke passed for ${sha:-unknown}"
