#!/usr/bin/env bash
# patch-health.sh — dry-run probe: do the CURRENT ASK kernel patches apply to
# the target linux-6.6.y source tree, without modifying it?
#
# Source of truth for patches (in priority order):
#   1. work/derived/patches/kernel/   (output of derive-patches.sh, freshest)
#   2. release/patches/kernel/        (committed last-known-good)
#   3. work/reference/patches/kernel/ (raw upstream reference, fallback)
#
# Usage:
#   ./scripts/patch-health.sh                   # uses work/.kernel-version
#   ./scripts/patch-health.sh 6.6.123           # fetch then probe
#   ./scripts/patch-health.sh --source derived  # force fresh derivation output
#   ./scripts/patch-health.sh --source release  # force committed release/
#   ./scripts/patch-health.sh --source reference# force raw reference repo
#
# Exit codes:
#   0  all patches apply cleanly
#   1  at least one patch rejects

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git find jq

SOURCE=""
VERSION_ARG=""
while (( $# )); do
    case "$1" in
        --source) SOURCE="${2:?--source needs arg}"; shift 2 ;;
        -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
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

# ── Resolve patch source ────────────────────────────────────────────────
# Auto-pick priority:  work/derived/  →  release/  →  work/reference/
if [[ -z "$SOURCE" ]]; then
    if   [[ -d "$WORK_DIR/derived/patches/ask" ]]; then SOURCE="derived"
    elif [[ -d "$REPO_ROOT/release/patches/ask" ]]; then SOURCE="release"
    else                                                 SOURCE="reference"
    fi
fi

case "$SOURCE" in
    derived)
        [[ -d "$WORK_DIR/derived/patches" ]] \
            || err "work/derived/ not found — run ./scripts/derive-patches.sh first"
        PATCH_ROOT="$WORK_DIR/derived/patches"
        SDK_DIR="$PATCH_ROOT/kernel/sdk-sources"
        TAG="derived (work/derived)"
        ;;
    release)
        [[ -d "$REPO_ROOT/release/patches" ]] \
            || err "release/ not found — run ./scripts/publish-release.sh first"
        PATCH_ROOT="$REPO_ROOT/release/patches"
        SDK_DIR="$PATCH_ROOT/kernel/sdk-sources"
        RELEASE_SHA=""
        if [[ -f "$REPO_ROOT/release/manifest.json" ]]; then
            RELEASE_SHA=$(jq -r '.reference_sha // ""' "$REPO_ROOT/release/manifest.json" 2>/dev/null)
        fi
        TAG="release${RELEASE_SHA:+ @ ${RELEASE_SHA:0:12}}"
        ;;
    reference)
        [[ -d "$WORK_DIR/reference" ]] || "$SCRIPTS_DIR/fetch-reference.sh"
        PATCH_ROOT="$WORK_DIR/reference/patches"
        SDK_DIR="$PATCH_ROOT/kernel/sdk-sources"
        TAG="reference @ $(cat "$WORK_DIR/.reference-sha" 2>/dev/null | cut -c1-12)"
        ;;
    *) err "unknown --source '$SOURCE' (use: derived | release | reference)" ;;
esac

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
if [[ -d "$SDK_DIR" ]]; then
    echo | tee -a "$SUMMARY"
    info "checking SDK source path conflicts…"
    SDK_CONFLICTS=0; SDK_TOTAL=0
    while IFS= read -r f; do
        SDK_TOTAL=$((SDK_TOTAL+1))
        [[ -e "$KDIR/$f" ]] && SDK_CONFLICTS=$((SDK_CONFLICTS+1))
    done < <(cd "$SDK_DIR" && find . -type f | sed 's|^\./||')
    if (( SDK_CONFLICTS > 0 )); then
        warn "$SDK_CONFLICTS of $SDK_TOTAL SDK file(s) already exist (ASK will overwrite)"
    else
        ok "no SDK file conflicts ($SDK_TOTAL files to install)"
    fi
    echo "SDK files: $SDK_TOTAL, conflicts: $SDK_CONFLICTS" >> "$SUMMARY"
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