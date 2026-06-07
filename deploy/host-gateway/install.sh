#!/usr/bin/env bash
set -euo pipefail
umask 027

SRC_REPO="${1:-/opt/hermes-webui/repo}"
INSTALL_DIR='/usr/local/lib/hermes-webui-control'
BIN='/usr/local/sbin/hermes-webui-control'
DOC_DIR='/usr/local/share/doc/hermes-webui-control'
BRANCH_FILE="$INSTALL_DIR/approved-branch"
RELEASES_FILE="$INSTALL_DIR/approved-releases.tsv"
AUDIT_DIR='/opt/hermes-webui/audit'
BACKUP_DIR='/opt/hermes-webui/backups'
LOG_DIR='/opt/hermes-webui/logs'
RELEASE_DIR='/opt/hermes-webui/releases'

log() {
  printf '[install] %s\n' "$*"
}

die() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die 'must run as root'
}

require_source_repo() {
  [ -d "$SRC_REPO/.git" ] || die "missing source repo checkout: $SRC_REPO"
}

install_root_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  install -D -o root -g root -m "$mode" "$src" "$dst"
}

write_default_branch() {
  local branch
  branch="$(git -C "$SRC_REPO" branch --show-current 2>/dev/null || true)"
  if [ -z "$branch" ] || [ "$branch" = 'HEAD' ]; then
    branch='feature/local-first-admin-console'
  fi
  printf '%s\n' "$branch" > "$BRANCH_FILE"
  chown root:root "$BRANCH_FILE"
  chmod 0644 "$BRANCH_FILE"
}

ensure_dirs() {
  install -d -o root -g root -m 0755 "$INSTALL_DIR" "$DOC_DIR" "$AUDIT_DIR" "$AUDIT_DIR/ops" "$BACKUP_DIR" "$LOG_DIR" "$RELEASE_DIR"
  install -d -o root -g root -m 0755 "$(dirname "$BIN")"
}

main() {
  require_root
  require_source_repo
  ensure_dirs

  log 'installing immutable control scripts'
  install_root_file "$SRC_REPO/deploy/host-gateway/hermes-webui-control" "$BIN" 0755
  install_root_file "$SRC_REPO/deploy/lib.sh" "$INSTALL_DIR/lib.sh" 0644
  install_root_file "$SRC_REPO/deploy/build.sh" "$INSTALL_DIR/build" 0755
  install_root_file "$SRC_REPO/deploy/deploy.sh" "$INSTALL_DIR/deploy" 0755
  install_root_file "$SRC_REPO/deploy/rollback.sh" "$INSTALL_DIR/rollback" 0755
  install_root_file "$SRC_REPO/deploy/smoke.sh" "$INSTALL_DIR/smoke" 0755
  install_root_file "$SRC_REPO/deploy/status.sh" "$INSTALL_DIR/status" 0755
  install_root_file "$SRC_REPO/deploy/host-gateway/authorized_keys.example" "$DOC_DIR/authorized_keys.example" 0644
  install_root_file "$SRC_REPO/deploy/host-gateway/sudoers.example" "$DOC_DIR/sudoers.example" 0644

  if [ ! -f "$RELEASES_FILE" ]; then
    printf '# sha | status | note\n' > "$RELEASES_FILE"
    chown root:root "$RELEASES_FILE"
    chmod 0644 "$RELEASES_FILE"
  fi

  write_default_branch

  log 'installed:'
  log "  $BIN"
  log "  $INSTALL_DIR/{lib.sh,build,deploy,rollback,smoke,status}"
  log "  $DOC_DIR/authorized_keys.example"
  log "  $BRANCH_FILE"
  log "  $RELEASES_FILE"
  log 'access is NOT enabled by this script'
}

main "$@"
