#!/usr/bin/env bash
# build-ask-modules.sh — cross-compile ASK out-of-tree kernel modules
# (cdx, fci, auto_bridge) against an already-built kernel tree, and pack the
# three .ko files into a single Debian package: ask-modules-<KVER>-ask.
#
# Prerequisites:
#   - scripts/build-kernel.sh has already run (so Module.symvers exists under
#     work/linux-<KVER>/).
#   - work/upstream.git/ contains the ASK mirror at UPSTREAM_BASELINE — i.e.
#     scripts/fetch-upstream.sh has run at some point. The source for the
#     three modules is pulled from there via `git archive`, not a working
#     clone, so there is no third on-disk copy of the ASK tree.
#
# Pipeline position: after build-kernel, before publish-binaries.
#
# Usage:
#   ./scripts/build-ask-modules.sh                  # default paths
#   ./scripts/build-ask-modules.sh --kdir /path     # override kernel tree
#   ./scripts/build-ask-modules.sh --platform LS1046A  # default; see Makefile
#
# Outputs:
#   work/build/ask-modules-<KVER>-ask_<KVER>-1_arm64.deb
#   work/ask-oot/build/{cdx,fci,auto_bridge}.ko  (intermediate, stripped)
#
# Exit codes:
#   0  .deb built and placed in work/build/
#   1  missing prerequisites, build failure, or packaging failure

set -euo pipefail
source "$(dirname "$0")/common.sh"

# ── Config ──────────────────────────────────────────────────────────────
PLATFORM="${PLATFORM:-LS1046A}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${ARCH:-arm64}"
KDIR_ARG=""

while (( $# )); do
    case "$1" in
        --kdir)     KDIR_ARG="${2:?--kdir needs arg}";     shift 2 ;;
        --platform) PLATFORM="${2:?--platform needs arg}"; shift 2 ;;
        -h|--help)  sed -n '1,32p' "$0"; exit 0 ;;
        *)          err "unknown arg: $1" ;;
    esac
done

need make git dpkg-deb

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 \
    || err "cross toolchain missing: ${CROSS_COMPILE}gcc"

# ── Resolve kernel tree ─────────────────────────────────────────────────
if [[ -n "$KDIR_ARG" ]]; then
    KDIR="$KDIR_ARG"
else
    [[ -f "$WORK_DIR/.kernel-version" ]] || err "no kernel fetched; run fetch-kernel.sh first"
    KVER=$(cat "$WORK_DIR/.kernel-version")
    KDIR="$WORK_DIR/linux-$KVER"
fi

[[ -f "$KDIR/Makefile" ]]         || err "$KDIR is not a kernel source tree"
[[ -f "$KDIR/.ask-applied" ]]     || err "tree is not ASK-applied — run apply-to-tree.sh first"
[[ -f "$KDIR/Module.symvers" ]]   || err "$KDIR/Module.symvers missing — run build-kernel.sh first"

KVER=$(awk '/^VERSION/{v=$3} /^PATCHLEVEL/{p=$3} /^SUBLEVEL/{s=$3} END{print v"."p"."s}' "$KDIR/Makefile")

# The in-tree kernel build produces modules with release string "<KVER>-ask"
# (LOCALVERSION=-ask from build-kernel.sh). The OOT modules must match that
# exact release string; the kernel tree itself encodes that via its own
# CONFIG_LOCALVERSION / localversion* files.
KRELEASE="${KVER}-ask"

# ── Resolve ASK source tree ─────────────────────────────────────────────
MIRROR="$WORK_DIR/upstream.git"
[[ -d "$MIRROR" ]] || err "upstream mirror missing; run fetch-upstream.sh first"

ASK_SHA="${UPSTREAM_TARGET:-${UPSTREAM_BASELINE:?}}"
# Resolve short SHA → full SHA so git archive is deterministic
ASK_SHA=$(git --git-dir="$MIRROR" rev-parse "$ASK_SHA^{commit}" 2>/dev/null) \
    || err "cannot resolve ASK commit: ${UPSTREAM_TARGET:-$UPSTREAM_BASELINE}"

SRC_ROOT="$WORK_DIR/ask-oot/src"
BUILD_ROOT="$WORK_DIR/ask-oot/build"
STAGING="$WORK_DIR/ask-oot/staging"

info "building ASK out-of-tree modules"
dim "   kernel tree:  $KDIR"
dim "   kernel rel:   $KRELEASE"
dim "   ASK commit:   ${ASK_SHA:0:12}"
dim "   platform:     $PLATFORM"
dim "   cross:        ${CROSS_COMPILE}gcc"

rm -rf "$SRC_ROOT" "$BUILD_ROOT" "$STAGING"
mkdir -p "$SRC_ROOT" "$BUILD_ROOT" "$STAGING"

# Extract the three module trees from the bare mirror
begin_group "extract ASK sources"
for dir in cdx fci auto_bridge; do
    git --git-dir="$MIRROR" archive "$ASK_SHA" -- "$dir" \
        | tar -C "$SRC_ROOT" -x
    [[ -d "$SRC_ROOT/$dir" ]] || err "extraction failed for $dir"
    ok "extracted $dir ($(find "$SRC_ROOT/$dir" -name '*.c' | wc -l) .c files)"
done
end_group

# ── Build each module ───────────────────────────────────────────────────
#
# The three modules have subtly different Makefile conventions:
#   - cdx/Makefile      uses KERNELDIR + PLATFORM (its own wrapper target)
#   - fci/Makefile      uses KERNEL_SOURCE, expects KBUILD_EXTRA_SYMBOLS
#   - auto_bridge/Makefile uses KERNEL_SOURCE, expects PLATFORM
#
# For all three we call them in "M=<dir>" shape so the kernel build system
# drives the actual compile. Module.symvers is threaded forward: fci depends
# on cdx's exports, auto_bridge on both.

COMMON_MAKE=(
    "ARCH=$ARCH"
    "CROSS_COMPILE=$CROSS_COMPILE"
    "PLATFORM=$PLATFORM"
    "KERNELDIR=$KDIR"
    "KERNEL_SOURCE=$KDIR"
    "KERNEL_SRC=$KDIR"
)

build_mod() {
    local name="$1"
    local dir="$SRC_ROOT/$name"
    local log="$BUILD_ROOT/${name}.log"

    # Thread accumulated Module.symvers from previous OOT builds so that the
    # dependent module finds the exports (fci needs cdx; auto_bridge may
    # reference cdx and fci symbols).
    local extra_symvers=""
    if [[ -s "$BUILD_ROOT/Module.symvers" ]]; then
        extra_symvers="$BUILD_ROOT/Module.symvers"
    fi

    info "  compiling $name"
    dim "    log: $log"
    set +e
    (
        cd "$dir" \
            && make "${COMMON_MAKE[@]}" \
                KBUILD_EXTRA_SYMBOLS="$extra_symvers" \
                -j"$(nproc_any)" modules 2>&1
    ) > "$log"
    local rc=$?
    set -e
    if (( rc != 0 )); then
        warn "last 40 lines of $log:"
        tail -40 "$log" >&2
        err "$name build failed (exit $rc)"
    fi

    # Collect the .ko and merge its symbols
    local ko
    ko=$(find "$dir" -maxdepth 2 -name "${name}.ko" -print -quit)
    [[ -n "$ko" ]] || err "$name build succeeded but ${name}.ko not found in $dir"
    cp -v "$ko" "$BUILD_ROOT/" >/dev/null
    "${CROSS_COMPILE}strip" --strip-unneeded "$BUILD_ROOT/${name}.ko"
    ok "    → $(basename "$ko") ($(du -h "$BUILD_ROOT/${name}.ko" | cut -f1))"

    # Merge this module's Module.symvers into the accumulator, if present
    local ms="$dir/Module.symvers"
    if [[ -f "$ms" ]]; then
        cat "$ms" >> "$BUILD_ROOT/Module.symvers"
        # Deduplicate (sort -u); kernel cares about unique entries
        sort -u "$BUILD_ROOT/Module.symvers" -o "$BUILD_ROOT/Module.symvers"
    fi
}

begin_group "compile OOT modules (cdx → fci → auto_bridge)"
: > "$BUILD_ROOT/Module.symvers"
build_mod cdx
build_mod fci
build_mod auto_bridge
end_group

# ── Verify vermagic ─────────────────────────────────────────────────────
begin_group "verify module vermagic matches kernel"
vermagic_ok=1
for m in cdx fci auto_bridge; do
    vm=$("${CROSS_COMPILE}objdump" -t "$BUILD_ROOT/${m}.ko" 2>/dev/null \
        | grep -oE '__module_depends|__versions' | head -1 || true)
    # Extract vermagic string from the .modinfo section
    vm=$("${CROSS_COMPILE}objcopy" --dump-section .modinfo=/dev/stdout "$BUILD_ROOT/${m}.ko" 2>/dev/null \
        | tr '\0' '\n' | grep '^vermagic=' | head -1 | cut -d= -f2-)
    if [[ -z "$vm" ]]; then
        warn "  $m: could not extract vermagic"
        continue
    fi
    if [[ "$vm" == "$KRELEASE "* ]]; then
        ok "  $m: vermagic='$vm'"
    else
        warn "  $m: vermagic='$vm' (expected prefix '$KRELEASE ')"
        vermagic_ok=0
    fi
done
(( vermagic_ok )) || err "vermagic mismatch: modules will not load on the built kernel"
end_group

# ── Stage for packaging ─────────────────────────────────────────────────
MOD_DIR="$STAGING/lib/modules/$KRELEASE/extra/ask"
mkdir -p "$MOD_DIR"
cp -v "$BUILD_ROOT"/{cdx,fci,auto_bridge}.ko "$MOD_DIR/" >/dev/null

mkdir -p "$STAGING/etc/modules-load.d"
cat > "$STAGING/etc/modules-load.d/ask.conf" <<'EOF'
# Load NXP ASK fast-path modules at boot.
# Order matters: cdx provides symbols consumed by fci and auto_bridge.
cdx
fci
auto_bridge
EOF

# DEBIAN control metadata
PKG_VER="${KVER}-1"
PKG_NAME="ask-modules-${KRELEASE}"
DEBIAN_DIR="$STAGING/DEBIAN"
mkdir -p "$DEBIAN_DIR"

cat > "$DEBIAN_DIR/control" <<EOF
Package: $PKG_NAME
Source: ask-modules
Version: $PKG_VER
Architecture: arm64
Maintainer: ASK LTS 6.6 Autobuilder <ci@localhost>
Installed-Size: $(du -sk "$STAGING" | cut -f1)
Depends: linux-image-${KRELEASE} (= $PKG_VER)
Section: kernel
Priority: optional
Description: NXP ASK out-of-tree kernel modules (cdx, fci, auto_bridge)
 Out-of-tree fast-path offload modules that register handlers for the ASK
 hook sites compiled into linux-image-${KRELEASE}.
 .
 Without this package installed, the in-tree ASK hook sites remain present
 but dormant: every packet falls through to the Linux slow path.
 .
 Built from we-are-mono/ASK @ ${ASK_SHA:0:12} against linux-$KVER.
EOF

cat > "$DEBIAN_DIR/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "configure" ]; then
    depmod -a "$KRELEASE" || true
fi
exit 0
EOF
chmod 755 "$DEBIAN_DIR/postinst"

cat > "$DEBIAN_DIR/postrm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
    depmod -a "$KRELEASE" 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$DEBIAN_DIR/postrm"

# ── Build the .deb ──────────────────────────────────────────────────────
OUT_DIR="$WORK_DIR/build"
mkdir -p "$OUT_DIR"
DEB_FILE="$OUT_DIR/${PKG_NAME}_${PKG_VER}_arm64.deb"

info "packing $DEB_FILE"
# --root-owner-group: force all files to root:root in the archive, matching
# what Debian expects and avoiding leaking the runner's UID.
dpkg-deb --root-owner-group --build "$STAGING" "$DEB_FILE" >/dev/null

ok "built $(basename "$DEB_FILE") ($(du -h "$DEB_FILE" | cut -f1))"

# ── Summary ─────────────────────────────────────────────────────────────
echo
info "── ask-modules build summary ──"
printf '   package:    %s\n' "$PKG_NAME"
printf '   version:    %s\n' "$PKG_VER"
printf '   depends on: linux-image-%s (= %s)\n' "$KRELEASE" "$PKG_VER"
printf '   file:       %s\n' "$DEB_FILE"
printf '   modules:\n'
for m in cdx fci auto_bridge; do
    printf '     /lib/modules/%s/extra/ask/%s.ko (%s)\n' \
        "$KRELEASE" "$m" "$(du -h "$BUILD_ROOT/${m}.ko" | cut -f1)"
done