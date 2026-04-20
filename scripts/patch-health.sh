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

need patch find

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
    if   [[ -d "$WORK_DIR/derived/patches/kernel" ]]; then SOURCE="derived"
    elif [[ -d "$REPO_ROOT/release/patches/kernel" ]];  then SOURCE="release"
    else                                                     SOURCE="reference"
    fi
fi

case "$SOURCE" in
    derived)
        [[ -d "$WORK_DIR/derived/patches/kernel" ]] \
            || err "work/derived/ not found — run ./scripts/derive-patches.sh first"
        PATCH_DIR="$WORK_DIR/derived/patches/kernel"
        SDK_DIR="$PATCH_DIR/sdk-sources"
        TAG="derived (work/derived)"
        ;;
    release)
        [[ -d "$REPO_ROOT/release/patches/kernel" ]] \
            || err "release/ not found — run ./scripts/publish-release.sh first"
        PATCH_DIR="$REPO_ROOT/release/patches/kernel"
        SDK_DIR="$PATCH_DIR/sdk-sources"
        RELEASE_SHA=""
        if [[ -f "$REPO_ROOT/release/manifest.json" ]] && command -v jq >/dev/null 2>&1; then
            RELEASE_SHA=$(jq -r '.reference_sha // ""' "$REPO_ROOT/release/manifest.json" 2>/dev/null)
        fi
        TAG="release${RELEASE_SHA:+ @ ${RELEASE_SHA:0:12}}"
        ;;
    reference)
        [[ -d "$WORK_DIR/reference" ]] || "$SCRIPTS_DIR/fetch-reference.sh"
        PATCH_DIR="$WORK_DIR/reference/patches/kernel"
        SDK_DIR="$PATCH_DIR/sdk-sources"
        TAG="reference @ $(cat "$WORK_DIR/.reference-sha" 2>/dev/null | cut -c1-12)"
        ;;
    *) err "unknown --source '$SOURCE' (use: derived | release | reference)" ;;
esac

# ── Discover patch files (prefer series file) ───────────────────────────
SERIES_FILE="$PATCH_DIR/series"
PATCHES=()
if [[ -f "$SERIES_FILE" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"; line="${line// /}"
        [[ -n "$line" ]] && PATCHES+=("$PATCH_DIR/$line")
    done < "$SERIES_FILE"
    info "using series file (${#PATCHES[@]} patches)"
else
    while IFS= read -r p; do PATCHES+=("$p"); done \
        < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | sort)
    dim "no series file; using sorted *.patch glob (${#PATCHES[@]} patches)"
fi
(( ${#PATCHES[@]} )) || err "no patches found in $PATCH_DIR"

# ── Header ──────────────────────────────────────────────────────────────
SUMMARY="$WORK_DIR/patch-health.txt"
{
    echo "=== Patch health probe ==="
    echo "Kernel:     linux-$KVER ($KDIR)"
    echo "Source:     $SOURCE  ($TAG)"
    echo "Patch dir:  $PATCH_DIR"
    echo "Patches:    ${#PATCHES[@]}"
    echo "Run at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} | tee "$SUMMARY"

# ── Dry-run each patch ──────────────────────────────────────────────────
PASS=0; FAIL=0
FAILED=()

for p in "${PATCHES[@]}"; do
    name="$(basename "$p")"
    if out=$(patch --dry-run -p1 -F0 -t -d "$KDIR" < "$p" 2>&1); then
        printf '  %s ✓%s %s\n' "$_C_GRN" "$_C_RST" "$name" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    else
        printf '  %s ✗%s %s\n' "$_C_RED" "$_C_RST" "$name" | tee -a "$SUMMARY"
        echo "$out" | grep -E '(FAILED|Hunk #|saving rejects)' \
            | sed 's/^/      /' | tee -a "$SUMMARY"
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