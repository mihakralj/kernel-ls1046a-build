#!/usr/bin/env bash
# fetch-upstream.sh — mirror the ASK source repo (mihakralj/ask-ls1046a-6.6)
# into a bare git dir so we can walk commit history and extract snapshots
# of specific files at specific SHAs.
#
# Post-pivot (see versions.lock note), this is the same repo as
# REFERENCE_REPO. The derivation engine now compares "what changed in this
# repo between BASELINE SHA and HEAD of UPSTREAM_BRANCH" — incremental
# tracking within a single tree, not cross-branch derivation.
#
# Usage:
#   ./scripts/fetch-upstream.sh
#
# Env vars:
#   UPSTREAM_REPO     default: https://github.com/mihakralj/ask-ls1046a-6.6.git
#   UPSTREAM_BRANCH   default: main
#
# Side effects:
#   work/upstream.git/        (bare mirror)
#   work/.upstream-head       (current HEAD SHA of UPSTREAM_BRANCH)

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git

# Load versions.lock
if [[ -f "$REPO_ROOT/versions.lock" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/versions.lock"
fi

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/mihakralj/ask-ls1046a-6.6.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

MIRROR="${WORK_DIR}/upstream.git"

ok   "Upstream repo:   $UPSTREAM_REPO"
info "Tracking branch: $UPSTREAM_BRANCH"

if [[ ! -d "$MIRROR" ]]; then
    info "cloning bare mirror (first run; full history) → $MIRROR"
    # No --quiet: CI wants progress on stderr (big repo, slow clone).
    git clone --bare --progress "$UPSTREAM_REPO" "$MIRROR"
else
    _prev_head=$(git --git-dir="$MIRROR" rev-parse "$UPSTREAM_BRANCH" 2>/dev/null || echo '?')
    dim "updating mirror (was ${_prev_head:0:12})…"
    git --git-dir="$MIRROR" fetch --tags --prune origin
fi

HEAD_SHA=$(git --git-dir="$MIRROR" rev-parse "$UPSTREAM_BRANCH")
echo "$HEAD_SHA" > "$WORK_DIR/.upstream-head"   # legacy marker, kept for compat

# Normalised state: identity is the branch-tip commit SHA.
set +e
fetch_state_write "upstream" "$HEAD_SHA"
STATE_RC=$?
set -e

ok "upstream mirror at: $MIRROR"
echo "   HEAD of $UPSTREAM_BRANCH: ${HEAD_SHA:0:12}"
git --git-dir="$MIRROR" log -1 --format='   %h  %s%n   author: %an, %ar' "$UPSTREAM_BRANCH" \
    | sed 's/^/   /'
exit "$STATE_RC"
