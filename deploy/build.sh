#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cd "$(repo_root_path)"
require_cmd git

sha="${1:-$(git_sha)}"
image_tag="${HERMES_WEBUI_IMAGE_PREFIX:-hermes-webui}:${sha}"

if ! is_true "${ENABLE_HINDSIGHT:-false}"; then
  ensure_hindsight_default_policy_sources
fi

require_cmd docker

log "building ${image_tag}"
docker build \
  --build-arg HERMES_VERSION="$sha" \
  -t "$image_tag" \
  -f Dockerfile \
  .

if is_true "${ENABLE_HINDSIGHT:-false}"; then
  log "verifying hindsight-client==0.7.2 inside ${image_tag}"
  docker run --rm --entrypoint python "$image_tag" - <<'PY'
import importlib.metadata as metadata
version = metadata.version('hindsight-client')
assert version == '0.7.2', version
print(version)
PY
else
  log "verifying hindsight-client is absent inside ${image_tag}"
  docker run --rm --entrypoint python "$image_tag" - <<'PY'
import importlib.metadata as metadata
try:
    version = metadata.version('hindsight-client')
except metadata.PackageNotFoundError:
    print('absent')
else:
    raise SystemExit(f'unexpected hindsight-client installed: {version}')
PY
fi

record_audit "build" "image=${image_tag} hindsight=${ENABLE_HINDSIGHT:-false} sha=${sha}"
printf '%s\n' "$image_tag"
