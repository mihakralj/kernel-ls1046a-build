#!/usr/bin/env bash
# patch-health.sh — dry-run probe: do the CURRENT ASK kernel patches apply to
# the target linux-6.6.y source tree, without modifying it?
#
# Source of truth: release/ (committed in this repo).
#
# Usage:
#   ./scripts/patch-health.sh                   # uses work/.kernel-version
#   ./scripts/patch-health.sh 6.6.123           # fetch then probe
#
# Exit codes:
#   0  all patches apply cleanly
#   1  at least one patch rejects

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git find jq

VERSION_ARG=""
while (( $# )); do
    case "$1" in
        --source) shift 2 ;;  # accepted-and-ignored for back-compat
        -h|--help) sed -n '1,18p' "$0"; exit 0 ;;
        *) VERSION_ARG="$1"; shift ;;
    esac
done

# ── Ensure kernel source is present ─────────────────────────────────────
if [[ -n "$VERSION_ARG" || ! -f "$WORK_DIR/.kernel-version" ]]; then
    "$SCRIPTS_DIR/fetch-kernel.sh" $VERSION_ARG
fi
KVER=$(cat "$WORK_DIR/.kernel-version")
KDIR="$WORK_DIR/linux-$KVER"
[[ -d "$KDIR" ]] || err "kernel source missing: $KDIR"

# ── Resolve patch source (release/ is the only source of truth) ─────────
SOURCE="release"
[[ -d "$REPO_ROOT/release/patches" ]] \
    || err "release/patches/ not found in repo"
PATCH_ROOT="$REPO_ROOT/release/patches"
SDK_DIR="$PATCH_ROOT/kernel/sdk-sources"
ASK_ITER=""
if [[ -f "$REPO_ROOT/release/manifest.json" ]]; then
    ASK_ITER=$(jq -r '.ask_iteration // ""' "$REPO_ROOT/release/manifest.json" 2>/dev/null)
fi
TAG="release${ASK_ITER:+ @ $ASK_ITER}"

# ── Discover patch files: vyos/ → ask/ → fixes/ ─────────────────────────
# Patches live under three subdirs that mirror ASK-mono organisation:
#   vyos/   → VyOS deltas (link_filter sysctl, inotify, perf packaging)
#   ask/    → ASK fast-path bucketed by ASK-mono boundaries (010..080)
#   fixes/  → 6.6.y-specific repairs/lockdep fixes (090+)
# Apply order is required: vyos first, then ask, then fixes. Within each
# subdir, sort by filename (numeric prefix orders ASK-mono buckets).
PATCHES=()
for sub in vyos ask fixes; do
    [[ -d "$PATCH_ROOT/$sub" ]] || continue
    while IFS= read -r p; do PATCHES+=("$p"); done \
        < <(find "$PATCH_ROOT/$sub" -maxdepth 1 -type f -name '*.patch' | sort)
done
(( ${#PATCHES[@]} )) || err "no patches found under $PATCH_ROOT/{vyos,ask,fixes}/"
dim "discovered ${#PATCHES[@]} patches across vyos/ ask/ fixes/"

# ── Stage SDK sources into the tree ─────────────────────────────────────
# Some patches (e.g. fixes/098-fm-cc-ehash-redirect.patch) target files that
# only exist after `apply-to-tree.sh` has copied the verbatim NXP SDK source
# drops into the kernel tree. Mirror that step here so `git apply --check`
# can resolve those paths. This is dry-run-safe: we only ADD files, never
# modify pristine kernel files, and the user is expected to re-extract the
# tree (as documented in AGENTS.md) before each run.
SDK_TOTAL_PRE=0; SDK_CONFLICTS_PRE=0; SDK_STAGED=0
if [[ -d "$SDK_DIR" ]]; then
    # Count conflicts BEFORE staging so the "files to install" assertion below
    # reports against the pristine tree, matching apply-to-tree.sh semantics.
    while IFS= read -r f; do
        SDK_TOTAL_PRE=$((SDK_TOTAL_PRE+1))
        [[ -e "$KDIR/$f" ]] && SDK_CONFLICTS_PRE=$((SDK_CONFLICTS_PRE+1))
    done < <(cd "$SDK_DIR" && find . -type f | sed 's|^\./||')

    info "staging SDK sources into kernel tree (so patches targeting SDK files can validate)"
    while IFS= read -r f; do
        dst="$KDIR/$f"
        if [[ ! -e "$dst" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp "$SDK_DIR/$f" "$dst"
            SDK_STAGED=$((SDK_STAGED+1))
        fi
    done < <(cd "$SDK_DIR" && find . -type f | sed 's|^\./||')
    dim "   staged $SDK_STAGED SDK file(s) for validation"
fi

# ── Header ──────────────────────────────────────────────────────────────
SUMMARY="$WORK_DIR/patch-health.txt"
{
    echo "=== Patch health probe ==="
    echo "Kernel:     linux-$KVER ($KDIR)"
    echo "Source:     $SOURCE  ($TAG)"
    echo "Patch root: $PATCH_ROOT  (vyos/ ask/ fixes/)"
    echo "Patches:    ${#PATCHES[@]}"
    echo "Run at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} | tee "$SUMMARY"

# ── Dry-run each patch ──────────────────────────────────────────────────
PASS=0; FAIL=0
FAILED=()

# Use `git apply --check` instead of `patch --dry-run -F0`. Advantages:
#   - zero fuzz by default (strict: any offset is a failure, not silent accept)
#   - works against a non-git target tree (does not require $KDIR/.git)
#   - informative error output (names the file + hunk that failed, not just
#     "Hunk #N FAILED at <offset>")
# `patch --dry-run -F0` was a loose approximation of the same thing; this
# tightens the contract so "health OK" means every hunk lands at the exact
# line numbers in the patch, which is what a reviewer actually wants to know.
for p in "${PATCHES[@]}"; do
    # Tag with parent subdir for clarity (e.g. "ask/060-…patch")
    name="$(basename "$(dirname "$p")")/$(basename "$p")"
    # --unsafe-paths is needed because $KDIR is an absolute path; without it
    # git apply rejects the first file as "invalid path". We are intentionally
    # applying outside any git worktree, which is what the flag unlocks.
    if out=$(git apply --check -p1 --unsafe-paths --directory="$KDIR" "$p" 2>&1); then
        printf '  %s ✓%s %s\n' "$_C_GRN" "$_C_RST" "$name" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    else
        printf '  %s ✗%s %s\n' "$_C_RED" "$_C_RST" "$name" | tee -a "$SUMMARY"
        # Surface every error line (git apply reports one per failing hunk).
        printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$SUMMARY"
        FAIL=$((FAIL+1))
        FAILED+=("$name")
    fi
done

# ── SDK source conflict check ───────────────────────────────────────────
# Reports the PRE-staging counts so the "files to install" invariant matches
# what apply-to-tree.sh sees on a freshly-extracted pristine tree.
if [[ -d "$SDK_DIR" ]]; then
    echo | tee -a "$SUMMARY"
    info "checking SDK source path conflicts…"
    if (( SDK_CONFLICTS_PRE > 0 )); then
        warn "$SDK_CONFLICTS_PRE of $SDK_TOTAL_PRE SDK file(s) already exist (ASK will overwrite)"
    else
        ok "no SDK file conflicts ($SDK_TOTAL_PRE files to install)"
    fi
    echo "SDK files: $SDK_TOTAL_PRE, conflicts: $SDK_CONFLICTS_PRE" >> "$SUMMARY"
fi

# ── Verdict ─────────────────────────────────────────────────────────────
echo | tee -a "$SUMMARY"
echo "=== Verdict ===" | tee -a "$SUMMARY"
printf 'Pass: %d   Fail: %d\n' "$PASS" "$FAIL" | tee -a "$SUMMARY"

if (( FAIL > 0 )); then
    echo "Failed patches:" | tee -a "$SUMMARY"
    printf '  %s\n' "${FAILED[@]}" | tee -a "$SUMMARY"
    err "patch rot detected against linux-$KVER"
fi
ok "all patches apply cleanly against linux-$KVER ($SOURCE)"