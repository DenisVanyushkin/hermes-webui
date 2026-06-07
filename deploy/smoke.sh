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

container_id="$(docker compose -f "$(compose_file_path)" ps -q "$service_name" 2>/dev/null || true)"
[ -n "$container_id" ] || die "compose service $service_name is not running"

curl -fsS "http://127.0.0.1:${port}/health" >/dev/null

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
  docker exec "$container_id" python - <<'PY'
import importlib.metadata as metadata
try:
    version = metadata.version('hindsight-client')
except metadata.PackageNotFoundError:
    print('absent')
else:
    raise SystemExit(f'unexpected hindsight-client installed: {version}')
PY
else
  docker exec "$container_id" python - <<'PY'
import importlib.metadata as metadata
version = metadata.version('hindsight-client')
assert version == '0.7.2', version
print(version)
PY
fi

record_audit "smoke" "sha=${sha} port=${port} hindsight=${ENABLE_HINDSIGHT:-false}"
log "smoke passed for ${sha:-unknown}"
