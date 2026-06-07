#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cd "$(repo_root_path)"
require_cmd git
require_cmd docker

sha="${1:-$(git_sha)}"
image_sha="${HERMES_WEBUI_IMAGE_PREFIX:-hermes-webui}:${sha}"
image_prod="${HERMES_WEBUI_IMAGE_PROD:-hermes-webui:prod}"
image_previous="${HERMES_WEBUI_IMAGE_PREVIOUS:-hermes-webui:previous}"

docker image inspect "$image_sha" >/dev/null 2>&1 || die "missing built image: $image_sha"

current_before="$(release_state_current)"
previous_before="$(release_state_previous)"
previous_state="${current_before:-$previous_before}"

if docker image inspect "$image_prod" >/dev/null 2>&1; then
  docker tag "$image_prod" "$image_previous"
fi
docker tag "$image_sha" "$image_prod"

record_history "deploy" "current=${sha} previous=${previous_state} image=${image_prod}"
record_audit "deploy" "current=${sha} previous=${previous_state}"

log "starting compose stack"
ENABLE_HINDSIGHT="${ENABLE_HINDSIGHT:-false}" \
HERMES_WEBUI_IMAGE="$image_prod" \
HERMES_WEBUI_GIT_SHA="$sha" \
docker compose -f "$(compose_file_path)" up -d --no-build

if ! bash "$SCRIPT_DIR/smoke.sh" "$sha"; then
  log "smoke failed; rolling back"
  bash "$SCRIPT_DIR/rollback.sh" "$current_before" "$previous_before"
  die "deploy smoke failed, rollback attempted"
fi

write_release_state "$(current_release_file)" "$sha"
if [ -n "$current_before" ]; then
  write_release_state "$(previous_release_file)" "$current_before"
else
  write_release_state "$(previous_release_file)" "${previous_before:-}"
fi
record_history "deploy-applied" "current=${sha} previous=${previous_state} image=${image_prod}"
record_audit "deploy-applied" "current=${sha} previous=${previous_state}"

log "deploy completed"
