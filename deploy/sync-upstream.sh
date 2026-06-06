#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

require_cmd git
cd "$(repo_root_path)"

upstream_remote="${UPSTREAM_REMOTE:-upstream}"
upstream_branch="${UPSTREAM_BRANCH:-master}"
if ! git remote get-url "$upstream_remote" >/dev/null 2>&1; then
  die "upstream remote not configured"
fi

git fetch "$upstream_remote" --prune
ensure_hindsight_default_policy_sources

echo "branch: $(git branch --show-current)"
echo "upstream: ${upstream_remote}/${upstream_branch}"
echo '--- ahead/behind ---'
git rev-list --left-right --count HEAD..."${upstream_remote}/${upstream_branch}"
echo '--- diffstat for deployment touchpoints ---'
git diff --stat HEAD..."${upstream_remote}/${upstream_branch}" -- \
  docker_init.bash api/startup.py bootstrap.py Dockerfile docker-compose.yml README.md ROADMAP.md CHANGELOG.md tests/test_issue926_hindsight_docker_dependency.py || true
echo '--- hindsight policy diff ---'
git diff HEAD..."${upstream_remote}/${upstream_branch}" -- docker_init.bash api/startup.py bootstrap.py tests/test_issue926_hindsight_docker_dependency.py | sed -n '1,220p' || true
record_audit "sync-upstream" "upstream=${upstream_remote}/${upstream_branch}"
