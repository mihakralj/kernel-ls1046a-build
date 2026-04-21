#!/usr/bin/env bash
# apply-to-tree.sh — wet-run counterpart of patch-health.sh.
#
# Takes a clean linux-6.6.y source tree and turns it into an ASK-ready tree by:
#   1. Copying release/patches/kernel/sdk-sources/ into the tree (67 files)
#   2. Applying release/patches/kernel/003-ask-kernel-hooks.patch (-p1)
#   3. Appending release/ask.config to arch/arm64/configs/defconfig
#      (or .config if present)
#   4. Running `make ARCH=arm64 olddefconfig` to resolve new symbols
#
# Source of truth for artefacts (same priority order as patch-health.sh):
#   1. work/derived/    (freshest)
#   2. release/         (committed last-known-good)
#   3. work/reference/  (raw upstream reference)
#
# Usage:
#   ./scripts/apply-to-tree.sh                      # auto-pick source + kernel
#   ./scripts/apply-to-tree.sh 6.6.123              # fetch/pin kernel first
#   ./scripts/apply-to-tree.sh --source release     # force committed tree
#   ./scripts/apply-to-tree.sh --kdir /path/to/src  # apply to an external tree
#   ./scripts/apply-to-tree.sh --defconfig foo      # seed config (default: defconfig)
#
# Exit codes:
#   0  tree is ASK-ready
#   1  patch rejects, missing source, or make olddefconfig failed

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git find cp make jq

SOURCE=""
VERSION_ARG=""
KDIR_ARG=""
DEFCONFIG="${KERNEL_DEFCONFIG:-defconfig}"

while (( $# )); do
    case "$1" in
        --source)    SOURCE="${2:?--source needs arg}"; shift 2 ;;
        --kdir)      KDIR_ARG="${2:?--kdir needs arg}";  shift 2 ;;
        --defconfig) DEFCONFIG="${2:?--defconfig needs arg}"; shift 2 ;;
        -h|--help)   sed -n '1,30p' "$0"; exit 0 ;;
        *)           VERSION_ARG="$1"; shift ;;
    esac
done

# ── Resolve kernel tree ─────────────────────────────────────────────────
if [[ -n "$KDIR_ARG" ]]; then
    KDIR="$KDIR_ARG"
    [[ -f "$KDIR/Makefile" ]] || err "$KDIR is not a kernel source tree (no Makefile)"
    KVER=$(awk '/^VERSION/{v=$3} /^PATCHLEVEL/{p=$3} /^SUBLEVEL/{s=$3} END{print v"."p"."s}' "$KDIR/Makefile")
else
    if [[ -n "$VERSION_ARG" || ! -f "$WORK_DIR/.kernel-version" ]]; then
        "$SCRIPTS_DIR/fetch-kernel.sh" $VERSION_ARG
    fi
    KVER=$(cat "$WORK_DIR/.kernel-version")
    KDIR="$WORK_DIR/linux-$KVER"
    [[ -d "$KDIR" ]] || err "kernel source missing: $KDIR"
fi

# ── Resolve artefact source ─────────────────────────────────────────────
if [[ -z "$SOURCE" ]]; then
    if   [[ -d "$WORK_DIR/derived/patches/kernel"  ]]; then SOURCE="derived"
    elif [[ -d "$REPO_ROOT/release/patches/kernel" ]]; then SOURCE="release"
    else                                                     SOURCE="reference"
    fi
fi

case "$SOURCE" in
    derived)
        PATCH_DIR="$WORK_DIR/derived/patches/kernel"
        CFG_FRAG="$WORK_DIR/derived/ask.config"
        TAG="derived"
        ;;
    release)
        PATCH_DIR="$REPO_ROOT/release/patches/kernel"
        CFG_FRAG="$REPO_ROOT/release/ask.config"
        TAG="release"
        ;;
    reference)
        [[ -d "$WORK_DIR/reference" ]] || "$SCRIPTS_DIR/fetch-reference.sh"
        PATCH_DIR="$WORK_DIR/reference/patches/kernel"
        CFG_FRAG="$WORK_DIR/reference/config/ask.config"
        TAG="reference"
        ;;
    *) err "unknown --source '$SOURCE' (use: derived | release | reference)" ;;
esac

[[ -d "$PATCH_DIR" ]]            || err "patch dir missing: $PATCH_DIR"
[[ -f "$CFG_FRAG" ]]             || err "config fragment missing: $CFG_FRAG"
SDK_DIR="$PATCH_DIR/sdk-sources"
HOOKS_PATCH="$PATCH_DIR/003-ask-kernel-hooks.patch"
[[ -f "$HOOKS_PATCH" ]]          || err "hooks patch missing: $HOOKS_PATCH"

info "applying ASK artefacts to kernel tree"
dim  "   kernel:  linux-$KVER ($KDIR)"
dim  "   source:  $SOURCE ($PATCH_DIR)"

# ── Idempotence guard ───────────────────────────────────────────────────
# Record a marker so we don't re-apply onto an already-ASK tree (the hooks
# patch is not idempotent — re-applying produces rejects).
MARKER="$KDIR/.ask-applied"
if [[ -f "$MARKER" ]]; then
    warn "tree is already ASK-applied (found $MARKER); refusing to re-apply"
    dim  "   remove the marker and re-extract the kernel tree to retry"
    exit 1
fi

# ── Step 1: copy SDK sources ────────────────────────────────────────────
info "step 1/4: copying SDK sources"
SDK_COUNT=0
while IFS= read -r f; do
    dst="$KDIR/$f"
    mkdir -p "$(dirname "$dst")"
    cp "$SDK_DIR/$f" "$dst"
    SDK_COUNT=$((SDK_COUNT+1))
done < <(cd "$SDK_DIR" && find . -type f | sed 's|^\./||')
ok "copied $SDK_COUNT SDK file(s)"

# ── Step 2: apply hooks patch ───────────────────────────────────────────
# Use `git apply` instead of `patch`. Advantages:
#   - zero fuzz by default (refuses to guess if context drifts)
#   - uniform behaviour with patch-health.sh (`git apply --check` dry-run)
#   - better error messages (names failing file + hunk, not cryptic
#     ".rej written to <path>" scatter)
# If a hunk fails, we fall back to `git apply --reject` which writes
# conflict markers into .rej files just like the old `patch` path did —
# so the maintainer-workflow on failure is unchanged.
info "step 2/4: applying 003-ask-kernel-hooks.patch"
# --unsafe-paths: $KDIR is an absolute path and we are intentionally applying
# outside any git worktree, which is what the flag unlocks.
if ! git apply -p1 --unsafe-paths --directory="$KDIR" "$HOOKS_PATCH" 2>&1; then
    warn "strict apply failed — retrying with --reject to surface failing hunks"
    git apply -p1 --unsafe-paths --directory="$KDIR" --reject "$HOOKS_PATCH" || true
    err "hooks patch failed to apply — see *.rej files under $KDIR"
fi
ok "hooks patch applied"

# ── Step 3: seed + append config ────────────────────────────────────────
info "step 3/4: configuring kernel ($DEFCONFIG + ask.config)"
if [[ ! -f "$KDIR/.config" ]]; then
    dim "   running: make ARCH=arm64 $DEFCONFIG"
    # Keep output visible in CI logs — if defconfig fails we want the
    # error message, not a silent exit.
    (cd "$KDIR" && make ARCH=arm64 "$DEFCONFIG" 2>&1 | tail -5) \
        || err "make $DEFCONFIG failed"
    ok "   seeded .config from $DEFCONFIG"
fi

# Disable conflicting mainline DPAA ETH before appending ASK options.
if grep -q '^CONFIG_FSL_DPAA_ETH=y' "$KDIR/.config" 2>/dev/null; then
    sed -i 's/^CONFIG_FSL_DPAA_ETH=y/# CONFIG_FSL_DPAA_ETH is not set/' "$KDIR/.config"
    dim "   disabled conflicting CONFIG_FSL_DPAA_ETH"
fi

echo ""                 >> "$KDIR/.config"
echo "# ── ASK fragment ──" >> "$KDIR/.config"
cat "$CFG_FRAG"         >> "$KDIR/.config"

# ── Step 4: olddefconfig to resolve new symbols ─────────────────────────
info "step 4/4: resolving config (make ARCH=arm64 olddefconfig)"
# Surface olddefconfig output — this is where you'd see "symbol foo is
# obsolete" or "new symbol bar, set to N" lines that reveal ask.config drift.
(cd "$KDIR" && make ARCH=arm64 olddefconfig 2>&1) \
    || err "make olddefconfig failed"

# ── Stamp the tree ──────────────────────────────────────────────────────
{
    echo "source=$SOURCE"
    echo "kernel=$KVER"
    echo "applied_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$SOURCE" == "release" && -f "$REPO_ROOT/release/manifest.json" ]]; then
        echo "reference_sha=$(jq -r '.reference_sha // ""' "$REPO_ROOT/release/manifest.json")"
    fi
} > "$MARKER"

ok "tree is ASK-ready: $KDIR"
echo
info "next: ./scripts/build-kernel.sh"