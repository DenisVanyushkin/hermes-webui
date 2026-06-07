#!/usr/bin/env bash

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

deploy_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

ts() {
  date -u +%Y%m%dT%H%M%SZ
}

log() {
  printf '[%s] %s\n' "$(ts)" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_dir() {
  mkdir -p "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

repo_root_path() {
  if [ -n "${REPO_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$REPO_ROOT_OVERRIDE"
  else
    repo_root
  fi
}

deploy_root_path() {
  printf '%s\n' "${DEPLOY_ROOT:-/opt/hermes-webui}"
}

compose_file_path() {
  printf '%s\n' "${COMPOSE_FILE:-$(deploy_script_dir)/docker-compose.local-first.yml}"
}

current_release_file() {
  printf '%s/releases/current\n' "$(deploy_root_path)"
}

previous_release_file() {
  printf '%s/releases/previous\n' "$(deploy_root_path)"
}

history_log_file() {
  printf '%s/releases/history.log\n' "$(deploy_root_path)"
}

audit_log_file() {
  printf '%s/audit/audit.log\n' "$(deploy_root_path)"
}

current_audit_dir() {
  printf '%s/audit\n' "$(deploy_root_path)"
}

current_backups_dir() {
  printf '%s/backups\n' "$(deploy_root_path)"
}

current_releases_dir() {
  printf '%s/releases\n' "$(deploy_root_path)"
}

git_sha() {
  cd "$(repo_root_path)" && git rev-parse --short=12 HEAD
}

release_state_current() {
  local f
  f="$(current_release_file)"
  [ -f "$f" ] && cat "$f" || true
}

release_state_previous() {
  local f
  f="$(previous_release_file)"
  [ -f "$f" ] && cat "$f" || true
}

write_release_state() {
  local path="$1"
  local value="$2"
  ensure_dir "$(dirname "$path")"
  printf '%s\n' "$value" > "$path"
}

runtime_health_url() {
  printf 'http://127.0.0.1:%s/health\n' "${HERMES_WEBUI_PORT:-8787}"
}

runtime_release_from_health_header() {
  local health_url server_header
  health_url="$(runtime_health_url)"
  server_header="$(curl -fsSI --max-time "${HERMES_WEBUI_HEALTH_TIMEOUT_SECONDS:-5}" "$health_url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "server:" { sub(/^[^:]+:[[:space:]]*/, "", $0); print; exit }')"
  server_header="${server_header%%[[:space:]]*}"
  case "$server_header" in
    HermesWebUI/*)
      printf '%s\n' "${server_header#HermesWebUI/}"
      return 0
      ;;
  esac
  return 1
}

repair_release_metadata_from_runtime() {
  local running current previous
  running="$(runtime_release_from_health_header)" || die "unable to determine running release from /health Server header"
  current="$(release_state_current)"
  previous="$(release_state_previous)"

  if [ -n "$current" ] && [ "$current" = "$running" ]; then
    log "release metadata already aligned with running release ${running}"
    return 0
  fi

  write_release_state "$(current_release_file)" "$running"
  if [ -n "$current" ]; then
    write_release_state "$(previous_release_file)" "$current"
  elif [ -z "$previous" ]; then
    write_release_state "$(previous_release_file)" ""
  fi

  record_history "repair" "current=${running} previous=${current:-$previous} source=runtime"
  record_audit "repair" "current=${running} previous=${current:-$previous} source=runtime"
  log "repaired release metadata from running release ${running}"
}

record_history() {
  ensure_dir "$(current_releases_dir)"
  printf '%s | %s | %s\n' "$(ts)" "$1" "$2" >> "$(history_log_file)"
}

record_audit() {
  ensure_dir "$(current_audit_dir)"
  printf '%s | %s | %s\n' "$(ts)" "$1" "$2" >> "$(audit_log_file)"
}

backup_sensitive_file() {
  local src="$1"
  local label="${2:-$(basename "$src")}"
  [ -e "$src" ] || die "backup source missing: $src"
  local backup_dir
  backup_dir="$(current_backups_dir)/$(ts)"
  ensure_dir "$backup_dir"
  cp -a "$src" "$backup_dir/$label"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$backup_dir/$label" > "$backup_dir/$label.sha256"
  fi
  printf '%s\n' "$backup_dir/$label"
}

port_is_free() {
  local port="${1:?port required}"
  python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', port))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
}

ensure_hindsight_default_policy_sources() {
  if is_true "${ENABLE_HINDSIGHT:-false}"; then
    return 0
  fi

  local repo
  repo="$(repo_root_path)"

  grep -Fq 'assert_hindsight_client_policy' "$repo/docker_init.bash" \
    || die "docker_init.bash is missing the explicit hindsight policy gate"
  if grep -Fq 'hindsight_client_requirement="hindsight-client>=0.4.22"' "$repo/docker_init.bash"; then
    die "docker_init.bash still contains the old unconditional hindsight install path"
  fi
  if grep -Fq 'ensure_hindsight_client_docker_dependency' "$repo/docker_init.bash"; then
    die "docker_init.bash still references the removed hindsight auto-install helper"
  fi
  grep -Fq '_hindsight_enabled' "$repo/bootstrap.py" \
    || die "bootstrap.py is missing the hindsight policy guard"
  grep -Fq '_hindsight_enabled' "$repo/api/startup.py" \
    || die "api/startup.py is missing the hindsight policy guard"
  grep -Fq 'HERMES_WEBUI_PYTHON: ${HERMES_WEBUI_PYTHON:-/app/venv/bin/python}' "$repo/deploy/docker-compose.local-first.yml" \
    || die "deploy/docker-compose.local-first.yml must default HERMES_WEBUI_PYTHON to /app/venv/bin/python"
  if grep -Fq '/opt/hermes-admin/hermes-home/hermes-agent/venv/bin/python' "$repo/deploy/docker-compose.local-first.yml"; then
    die "deploy/docker-compose.local-first.yml still references the host-mounted agent venv python"
  fi
}

report_release_state() {
  printf 'current=%s\n' "$(release_state_current)"
  printf 'previous=%s\n' "$(release_state_previous)"
}
