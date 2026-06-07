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

ensure_dir "$(current_releases_dir)"
printf '%s\n' "$sha" > "$(current_release_file)"
if [ -n "$current_before" ]; then
  printf '%s\n' "$current_before" > "$(previous_release_file)"
else
  printf '%s\n' "${previous_before:-}" > "$(previous_release_file)"
fi
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

log "deploy completed"
