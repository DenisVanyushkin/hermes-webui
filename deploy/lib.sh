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
