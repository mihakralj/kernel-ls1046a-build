#!/usr/bin/env bash
# build-ask-iptables.sh — cross-compile a patched Debian iptables source package
# for arm64 with the NXP ASK QOSMARK/QOSCONNMARK extensions applied.
#
# This single script covers both Phase 3 (xtables libxt_QOS*.so extensions)
# and Phase 4 (patched iptables binary), because the upstream ASK patch
# creates exactly the same set of new files needed for both: the .c/.h
# source files compile into the iptables-extensions .so plugins that ship
# inside libxtables12's extension directory. Rebuilding the Debian source
# package gives us consistent .debs that can be installed alongside the
# kernel without conflict.
#
# Prerequisites:
#   - work/upstream.git/ contains the ASK mirror (with
#     patches/iptables/001-qosmark-extensions.patch at UPSTREAM_BASELINE).
#     scripts/fetch-upstream.sh must have run at some point.
#   - Host has the Debian cross-build toolchain:
#       dpkg-dev debhelper dh-autoreconf quilt
#       gcc-aarch64-linux-gnu + dpkg-cross foreign arch
#     The CI workflow installs these in its "Install toolchain" step.
#
# Pipeline position: after build-ask-modules.sh (independent of it; the
# xtables rebuild has no FMan SDK dependency).
#
# Usage:
#   ./scripts/build-ask-iptables.sh
#   ./scripts/build-ask-iptables.sh --dist bookworm   # target distro (default: bookworm)
#   ./scripts/build-ask-iptables.sh --arch arm64      # default; target arch
#
# Outputs:
#   work/build/iptables_<ver>+ask1_arm64.deb
#   work/build/libxtables12_<ver>+ask1_arm64.deb
#   work/build/libip4tc2_<ver>+ask1_arm64.deb
#   work/build/libip6tc2_<ver>+ask1_arm64.deb
#   work/build/iptables-dev_<ver>+ask1_arm64.deb
#   work/build/iptables_<ver>+ask1_arm64.{changes,buildinfo}
#   work/ask-iptables/build.log
#
# Exit codes:
#   0  .debs built and placed in work/build/
#   1  missing prerequisites, apt-get source failure, or build failure
#   2  patch does not apply cleanly to the source tree

set -euo pipefail
source "$(dirname "$0")/common.sh"

# ── Config ──────────────────────────────────────────────────────────────
DIST="${DIST:-bookworm}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
REVISION_SUFFIX="${REVISION_SUFFIX:-+ask1}"
# Source package & upstream patch to apply
SRC_PKG="iptables"
PATCH_SUBPATH="patches/iptables/001-qosmark-extensions.patch"

while (( $# )); do
    case "$1" in
        --dist)    DIST="${2:?--dist needs arg}";          shift 2 ;;
        --arch)    TARGET_ARCH="${2:?--arch needs arg}";   shift 2 ;;
        --cross)   CROSS_COMPILE="${2:?--cross needs arg}"; shift 2 ;;
        -h|--help) sed -n '1,48p' "$0"; exit 0 ;;
        *)         err "unknown arg: $1" ;;
    esac
done

need apt-get dpkg-source dpkg-buildpackage git patch

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 \
    || err "cross toolchain missing: ${CROSS_COMPILE}gcc"

# ── Resolve patch ──────────────────────────────────────────────────────
MIRROR="$WORK_DIR/upstream.git"
[[ -d "$MIRROR" ]] || err "upstream mirror missing; run fetch-upstream.sh first"

ASK_SHA="${UPSTREAM_TARGET:-${UPSTREAM_BASELINE:?}}"
ASK_SHA=$(git --git-dir="$MIRROR" rev-parse "$ASK_SHA^{commit}" 2>/dev/null) \
    || err "cannot resolve ASK commit: ${UPSTREAM_TARGET:-$UPSTREAM_BASELINE}"

# ── Workspace ──────────────────────────────────────────────────────────
WS="$WORK_DIR/ask-iptables"
SRC_ROOT="$WS/src"
OUT_DIR="$WORK_DIR/build"
rm -rf "$WS"
mkdir -p "$SRC_ROOT" "$OUT_DIR"

info "building patched iptables (Debian source rebuild)"
dim "   source pkg:     $SRC_PKG"
dim "   patch commit:   ${ASK_SHA:0:12}"
dim "   target arch:    $TARGET_ARCH"
dim "   cross:          ${CROSS_COMPILE}gcc"
dim "   revision tag:   $REVISION_SUFFIX"
dim "   workspace:      $WS"

# ── Fetch source package ───────────────────────────────────────────────
begin_group "apt-get source $SRC_PKG"
# Use a sub-shell with a narrow CWD so dpkg-source drops files where we want.
(
    cd "$SRC_ROOT"
    # Some minimal CI images ship without deb-src entries; make sure we have them.
    if ! apt-cache showsrc "$SRC_PKG" 2>/dev/null | grep -q '^Package:'; then
        warn "no deb-src for $SRC_PKG; attempting to enable"
        # Enable deb-src for the current suite on a best-effort basis. On
        # GitHub Actions ubuntu-latest the sources.list has deb-src commented
        # out; flip the comments on. If this fails we let apt-get source fail
        # with a clear message.
        if [[ -w /etc/apt/sources.list ]]; then
            sed -i 's/^# *deb-src /deb-src /' /etc/apt/sources.list || true
            sudo apt-get update -qq || apt-get update -qq || true
        fi
    fi
    apt-get source "$SRC_PKG" 2>&1 | tail -10
) > "$WS/apt-source.log" 2>&1 \
    || { warn "apt-get source failed; see $WS/apt-source.log"; tail -40 "$WS/apt-source.log" >&2; err "cannot download $SRC_PKG source"; }

# Locate extracted tree
SRC_DIR=$(find "$SRC_ROOT" -mindepth 1 -maxdepth 1 -type d -name "${SRC_PKG}-*" | head -1)
[[ -d "$SRC_DIR" ]] || err "no ${SRC_PKG}-* directory after apt-get source"
DSC_FILE=$(find "$SRC_ROOT" -maxdepth 1 -name "${SRC_PKG}_*.dsc" | head -1)
[[ -f "$DSC_FILE" ]] || err "no ${SRC_PKG}_*.dsc after apt-get source"
UPSTREAM_VER=$(basename "$SRC_DIR" | sed -E "s/^${SRC_PKG}-//")
ok "fetched $SRC_PKG $UPSTREAM_VER into $(basename "$SRC_DIR")"
end_group

# ── Extract and apply the ASK patch ─────────────────────────────────────
begin_group "apply ASK QOSMARK/QOSCONNMARK patch"
PATCH_FILE="$WS/001-qosmark-extensions.patch"
git --git-dir="$MIRROR" show "$ASK_SHA:$PATCH_SUBPATH" > "$PATCH_FILE" \
    || err "cannot extract $PATCH_SUBPATH at $ASK_SHA"
ok "extracted patch ($(wc -l < "$PATCH_FILE") lines)"

# Dry-run first so we get a clear error before dirtying the tree.
if ! (cd "$SRC_DIR" && patch -p1 --dry-run --quiet < "$PATCH_FILE"); then
    warn "patch does not apply cleanly; showing diagnostic"
    (cd "$SRC_DIR" && patch -p1 --dry-run < "$PATCH_FILE") 2>&1 | tail -40 >&2
    exit 2
fi
(cd "$SRC_DIR" && patch -p1 --quiet < "$PATCH_FILE") \
    || err "patch application failed after dry-run succeeded (shouldn't happen)"
ok "patch applied to $(basename "$SRC_DIR")"

# Record the patch in debian/patches so dpkg-source -b can represent it,
# falling back to unapplied if quilt is configured for 3.0 (quilt) format.
if [[ -f "$SRC_DIR/debian/source/format" ]] \
    && grep -q '3.0 (quilt)' "$SRC_DIR/debian/source/format"; then
    mkdir -p "$SRC_DIR/debian/patches"
    cp "$PATCH_FILE" "$SRC_DIR/debian/patches/0999-ask-qosmark-extensions.patch"
    # Append to series (create if missing)
    touch "$SRC_DIR/debian/patches/series"
    grep -qx '0999-ask-qosmark-extensions.patch' \
        "$SRC_DIR/debian/patches/series" 2>/dev/null \
        || echo '0999-ask-qosmark-extensions.patch' \
            >> "$SRC_DIR/debian/patches/series"
    ok "registered patch in debian/patches/series"
fi
end_group

# ── Bump version with ASK suffix ───────────────────────────────────────
begin_group "record version + changelog entry"
export DEBEMAIL="${DEBEMAIL:-ci@localhost}"
export DEBFULLNAME="${DEBFULLNAME:-ASK LTS 6.6 Autobuilder}"
NEW_VER="${UPSTREAM_VER}${REVISION_SUFFIX}"
(
    cd "$SRC_DIR"
    # dch is part of devscripts; fallback to manual edit if absent.
    if command -v dch >/dev/null 2>&1; then
        dch --distribution "$DIST" --newversion "$NEW_VER" \
            "Apply NXP ASK QOSMARK/QOSCONNMARK extensions from ${ASK_SHA:0:12}."
    else
        # Manual changelog prepend. Format per deb-changelog(5).
        {
            printf '%s (%s) %s; urgency=medium\n\n' "$SRC_PKG" "$NEW_VER" "$DIST"
            printf '  * Apply NXP ASK QOSMARK/QOSCONNMARK extensions from %s.\n\n' \
                "${ASK_SHA:0:12}"
            printf ' -- %s <%s>  %s\n\n' \
                "$DEBFULLNAME" "$DEBEMAIL" "$(date -R)"
            cat debian/changelog
        } > debian/changelog.new
        mv debian/changelog.new debian/changelog
    fi
)
ok "new version: $NEW_VER"
end_group

# ── Cross-build ─────────────────────────────────────────────────────────
begin_group "dpkg-buildpackage (cross to $TARGET_ARCH)"
BUILD_LOG="$WS/build.log"
info "  target arch: $TARGET_ARCH"
dim "  log:         $BUILD_LOG"
set +e
(
    cd "$SRC_DIR"
    export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc_any)"
    export CONFIG_SITE="/etc/dpkg-cross/cross-config.${TARGET_ARCH}"
    dpkg-buildpackage \
        --host-arch "$TARGET_ARCH" \
        --build=binary \
        -uc -us \
        2>&1
) > "$BUILD_LOG"
rc=$?
set -e

if (( rc != 0 )); then
    warn "last 60 lines of $BUILD_LOG:"
    tail -60 "$BUILD_LOG" >&2
    err "dpkg-buildpackage failed (exit $rc)"
fi
end_group

# ── Collect artefacts ───────────────────────────────────────────────────
begin_group "collect produced .debs"
shopt -s nullglob
produced=( "$SRC_ROOT"/*"${REVISION_SUFFIX}"*"_${TARGET_ARCH}.deb"
           "$SRC_ROOT"/*"${REVISION_SUFFIX}"*"_all.deb"
           "$SRC_ROOT"/*"${REVISION_SUFFIX}"*".changes"
           "$SRC_ROOT"/*"${REVISION_SUFFIX}"*".buildinfo" )
shopt -u nullglob

if (( ${#produced[@]} == 0 )); then
    err "build completed but no .deb artefacts found in $SRC_ROOT"
fi

for f in "${produced[@]}"; do
    cp -v "$f" "$OUT_DIR/" | sed 's|^|   |'
done
end_group

# ── Summary ─────────────────────────────────────────────────────────────
echo
info "── ask-iptables build summary ──"
printf '   source:         %s %s\n'    "$SRC_PKG" "$UPSTREAM_VER"
printf '   new version:    %s\n'       "$NEW_VER"
printf '   patch commit:   %s\n'       "${ASK_SHA:0:12}"
printf '   target arch:    %s\n'       "$TARGET_ARCH"
printf '   produced:\n'
for f in "${produced[@]}"; do
    [[ "$f" == *.deb ]] && printf '     %s (%s)\n' \
        "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

# ── Note on what's inside ──────────────────────────────────────────────
# The four new source files from the upstream patch compile into:
#   /usr/lib/<triple>/xtables/libxt_qosmark.so
#   /usr/lib/<triple>/xtables/libxt_QOSMARK.so
#   /usr/lib/<triple>/xtables/libxt_qosconnmark.so
#   /usr/lib/<triple>/xtables/libxt_QOSCONNMARK.so
# delivered in the iptables binary package alongside the patched iptables
# binary. The kernel-side xt_QOSMARK / xt_QOSCONNMARK headers are already
# installed by the kernel linux-libc-dev .deb (via 003-ask-kernel-hooks.patch).