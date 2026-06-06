#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_cmd docker
image_prod="${HERMES_WEBUI_IMAGE_PROD:-hermes-webui:prod}"
image_previous="${HERMES_WEBUI_IMAGE_PREVIOUS:-hermes-webui:previous}"

current_before="${1:-$(release_state_current)}"
previous_before="${2:-$(release_state_previous)}"
[ -n "$previous_before" ] || die "no previous release recorded for rollback"

docker image inspect "$image_previous" >/dev/null 2>&1 || die "missing previous image tag: $image_previous"
docker tag "$image_previous" "$image_prod"

printf '%s\n' "$previous_before" > "$(current_release_file)"
printf '%s\n' "$current_before" > "$(previous_release_file)"
record_history "rollback" "current=${previous_before} previous=${current_before} image=${image_prod}"
record_audit "rollback" "current=${previous_before} previous=${current_before}"

ENABLE_HINDSIGHT="${ENABLE_HINDSIGHT:-false}" \
HERMES_WEBUI_IMAGE="$image_prod" \
docker compose -f "$(compose_file_path)" up -d --no-build

"$SCRIPT_DIR/smoke.sh" "$previous_before"
log "rollback complete"
