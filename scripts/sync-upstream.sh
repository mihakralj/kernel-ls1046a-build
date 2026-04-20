#!/usr/bin/env bash
# sync-upstream.sh — walk new commits on we-are-mono/ASK mt-6.12.y since the
# UPSTREAM_BASELINE pinned in versions.lock, and classify each into tiers:
#
#   T1  direct-apply   userspace / OOT modules / lib patches
#                      (no kernel-version coupling; cherry-pick-safe)
#   T2  port required  kernel patch changes (need re-derivation onto 6.6)
#   T3  meta           README / Makefile / build scripts
#
# This is a read-only informational tool. The actual derivation is done by
# derive-patches.sh. This script just tells you WHAT changed, so you can
# judge the scope of upcoming work.
#
# Usage:
#   ./scripts/sync-upstream.sh                       # uses UPSTREAM_BASELINE from versions.lock
#   ./scripts/sync-upstream.sh <baseline-sha>        # explicit baseline
#   ./scripts/sync-upstream.sh --since "2 weeks ago" # time-based
#
# Exit codes:
#   0  no new upstream commits, or only T1/T3 (safe to auto-pull)
#   2  at least one T2 commit (kernel patch work required)

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git

# Load versions.lock
if [[ -f "$REPO_ROOT/versions.lock" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/versions.lock"
fi

UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-mt-6.12.y}"

# Ensure upstream mirror exists
[[ -d "$WORK_DIR/upstream.git" ]] || "$SCRIPTS_DIR/fetch-upstream.sh"
MIRROR="$WORK_DIR/upstream.git"

# ── Resolve baseline SHA ────────────────────────────────────────────────
BASELINE=""
SINCE=""
if [[ "${1:-}" == "--since" ]]; then
    SINCE="${2:?--since requires a date expression}"
    info "Using time-based range: --since='$SINCE'"
elif [[ -n "${1:-}" ]]; then
    BASELINE="$1"
    info "Using explicit baseline: $BASELINE"
elif [[ -n "${UPSTREAM_BASELINE:-}" ]]; then
    BASELINE="$UPSTREAM_BASELINE"
    info "Baseline from versions.lock: $BASELINE"
fi

UPSTREAM_HEAD=$(git --git-dir="$MIRROR" rev-parse "$UPSTREAM_BRANCH")
UPSTREAM_HEAD_SHORT="${UPSTREAM_HEAD:0:12}"

# Build the revision range
RANGE_ARGS=()
if [[ -n "$BASELINE" ]]; then
    git --git-dir="$MIRROR" cat-file -e "${BASELINE}^{commit}" 2>/dev/null \
        || err "baseline '$BASELINE' not found in upstream mirror"
    RANGE_ARGS+=("${BASELINE}..${UPSTREAM_BRANCH}")
elif [[ -n "$SINCE" ]]; then
    RANGE_ARGS+=("--since=$SINCE" "$UPSTREAM_BRANCH")
else
    warn "no baseline and no --since; showing last 20 commits on $UPSTREAM_BRANCH"
    RANGE_ARGS+=("-n" "20" "$UPSTREAM_BRANCH")
fi

REPORT="$WORK_DIR/upstream-sync.txt"

# Per-commit tier classification is provided by common.sh::classify_commit
# (single source of truth shared with derive-patches.sh).

tier_colour() { case "$1" in T1) echo "$_C_GRN";; T2) echo "$_C_YEL";; T3) echo "$_C_BLUE";; esac; }
tier_label()  { case "$1" in T1) echo "T1 direct-apply  ";; T2) echo "T2 port required ";; T3) echo "T3 meta           ";; esac; }

{
    echo "=== ASK upstream sync report ==="
    echo "Upstream:      $UPSTREAM_REPO ($UPSTREAM_BRANCH)"
    echo "Upstream HEAD: $UPSTREAM_HEAD_SHORT"
    [[ -n "$BASELINE" ]] && echo "Baseline:      ${BASELINE:0:12}"
    [[ -n "$SINCE"    ]] && echo "Since:         $SINCE"
    echo "Run at:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} | tee "$REPORT"

# Collect commits (bash 3.2-compat: no mapfile)
COMMITS=()
while IFS= read -r _sha; do
    [[ -n "$_sha" ]] && COMMITS+=("$_sha")
done < <(git --git-dir="$MIRROR" log --reverse --format='%H' "${RANGE_ARGS[@]}")

if (( ${#COMMITS[@]} == 0 )); then
    ok "no new upstream commits — reference is up to date"
    exit 0
fi

# Bash 3.2-compat: plain counters instead of declare -A
T1_COUNT=0; T2_COUNT=0; T3_COUNT=0

echo "New commits: ${#COMMITS[@]}" | tee -a "$REPORT"
echo | tee -a "$REPORT"
printf '%-10s  %-20s  %s\n' "commit"    "tier"                "subject" | tee -a "$REPORT"
printf '%-10s  %-20s  %s\n' "---------" "--------------------" "-------" | tee -a "$REPORT"

for sha in "${COMMITS[@]}"; do
    subject=$(git --git-dir="$MIRROR" log -1 --format='%s' "$sha")
    tier=$(classify_commit "$MIRROR" "$sha")
    case "$tier" in
        T1) T1_COUNT=$((T1_COUNT+1)) ;;
        T2) T2_COUNT=$((T2_COUNT+1)) ;;
        T3) T3_COUNT=$((T3_COUNT+1)) ;;
    esac
    short="${sha:0:8}"
    label="$(tier_label "$tier")"
    colour="$(tier_colour "$tier")"
    printf '%s%-10s%s  %s%s%s  %s\n' \
        "$colour" "$short" "$_C_RST"  "$colour" "$label" "$_C_RST"  "$subject"
    printf '%-10s  %-20s  %s\n' "$short" "$label" "$subject" >> "$REPORT"
done

{
    echo
    echo "=== Summary ==="
    printf '  T1 direct-apply   : %d\n' "$T1_COUNT"
    printf '  T2 port required  : %d\n' "$T2_COUNT"
    printf '  T3 meta           : %d\n' "$T3_COUNT"
    echo
    cat <<EOF
Next steps:
  - T2 > 0  →  run ./scripts/derive-patches.sh to fold upstream kernel-patch
               changes onto the reference 6.6 port. Inspect rejects if any.
  - T1/T3   →  informational; these don't affect the 6.6 kernel patch.
               If you maintain a separate 6.6 module/userspace fork, cherry-pick
               there.
  - After a successful derivation, bump UPSTREAM_BASELINE in versions.lock to:
        $UPSTREAM_HEAD_SHORT
EOF
} | tee -a "$REPORT"

if (( T2_COUNT > 0 )); then
    warn "$T2_COUNT kernel-patch commit(s) require re-derivation"
    exit 2
fi

ok "no kernel-patch changes upstream — reference translation still current"