#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

current="$(release_state_current)"
previous="$(release_state_previous)"
port="${HERMES_WEBUI_PORT:-8787}"
image_prod="${HERMES_WEBUI_IMAGE_PROD:-hermes-webui:prod}"

echo "branch: $(git -C "$(repo_root_path)" branch --show-current 2>/dev/null || true)"
echo "repo: $(repo_root_path)"
echo "port: ${port}"
echo "hindsight-enabled: ${ENABLE_HINDSIGHT:-false}"
echo "current-release: ${current:-<none>}"
echo "previous-release: ${previous:-<none>}"
echo "image: ${image_prod}"
if command -v docker >/dev/null 2>&1; then
  if docker image inspect "$image_prod" >/dev/null 2>&1; then
    docker image inspect "$image_prod" --format 'image-id: {{.Id}}'
  else
    echo 'image-id: <missing>'
  fi
  echo '--- compose status ---'
  docker compose -f "$(compose_file_path)" ps 2>/dev/null || true
else
  echo 'docker: <unavailable>'
fi
echo '--- release history tail ---'
tail -n 10 "$(history_log_file)" 2>/dev/null || true
echo '--- audit tail ---'
tail -n 10 "$(audit_log_file)" 2>/dev/null || true
