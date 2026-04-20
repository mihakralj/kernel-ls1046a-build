#!/usr/bin/env bash
# fetch-reference.sh — clone the "reference" repo, i.e. the last-known-good
# 6.6 translation of ASK. This is STATIC — we treat it as the template that
# already solved "how does the 6.12 upstream map onto 6.6 kernel source?"
# and we only apply incremental upstream deltas on top.
#
# Usage:
#   ./scripts/fetch-reference.sh                    # uses ref in versions.lock
#   ./scripts/fetch-reference.sh main               # override ref
#
# Env vars:
#   REFERENCE_REPO   override repo URL
#
# Side effects:
#   work/reference/        (cloned tree — the 6.6 translation)
#   work/.reference-sha    (resolved commit SHA)

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git

# Load versions.lock if present
if [[ -f "$REPO_ROOT/versions.lock" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/versions.lock"
fi

REFERENCE_REPO="${REFERENCE_REPO:-https://github.com/mihakralj/ask-ls1046a-6.6.git}"
REF="${1:-${REFERENCE_REF:-main}}"
REF_DIR="${WORK_DIR}/reference"

ok "Reference repo:  ${REFERENCE_REPO}"
info "Target ref:      ${REF}"

if [[ -d "${REF_DIR}/.git" ]]; then
    dim "updating existing clone ($(git -C "$REF_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))…"
    git -C "$REF_DIR" fetch --tags --prune origin
else
    info "cloning $REFERENCE_REPO → $REF_DIR"
    rm -rf "$REF_DIR"
    # No --quiet: in CI we want progress on stderr so a slow network
    # doesn't look like a hang.
    git clone --progress "$REFERENCE_REPO" "$REF_DIR"
fi

SHA=""
for candidate in "$REF" "origin/$REF" "refs/tags/$REF"; do
    if SHA=$(git -C "$REF_DIR" rev-parse --verify --quiet "${candidate}^{commit}" 2>/dev/null); then
        break
    fi
done
[[ -n "$SHA" ]] || err "could not resolve ref '$REF'"

git -C "$REF_DIR" -c advice.detachedHead=false checkout --quiet "$SHA"
echo "$SHA" > "${WORK_DIR}/.reference-sha"   # legacy marker, kept for compat

# Sanity
for f in patches/kernel/003-ask-kernel-hooks.patch patches/kernel/sdk-sources config/ask.config; do
    [[ -e "$REF_DIR/$f" ]] || warn "expected reference file missing: $f"
done

# Normalised state: identity is the resolved commit SHA.
set +e
fetch_state_write "reference" "$SHA"
STATE_RC=$?
set -e

ok "reference ready: $REF_DIR @ ${SHA:0:12}"
git -C "$REF_DIR" log -1 --format='   %h  %s%n   author: %an, %ar' | sed 's/^/   /'
exit "$STATE_RC"
