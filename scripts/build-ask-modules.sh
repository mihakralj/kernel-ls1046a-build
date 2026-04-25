#!/usr/bin/env bash
# build-ask-modules.sh — natively build ASK out-of-tree kernel modules
# (cdx, fci, auto_bridge) against an already-built kernel tree, and pack the
# three .ko files into a single Debian package: ask-modules-<KVER>-vyos.
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
#   work/build/ask-modules-<KVER>-vyos_<KVER>-1_arm64.deb
#   work/ask-oot/build/{cdx,fci,auto_bridge}.ko  (intermediate, stripped)
#
# Exit codes:
#   0   .deb built and placed in work/build/
#   1   missing prerequisites, build failure, or packaging failure
#   77  soft-skip: NXP linux-lsdk FMan SDK layer absent in kernel tree
#       (run-pipeline.sh tolerates this via run_step_softfail 77; any other
#       non-zero exit is treated as a hard build failure)

set -euo pipefail
source "$(dirname "$0")/common.sh"

# ── Config ──────────────────────────────────────────────────────────────
PLATFORM="${PLATFORM:-LS1046A}"
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

need make git dpkg-deb gcc strip objdump objcopy

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

host_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
[[ "$host_arch" == "arm64" || "$host_arch" == "aarch64" ]] \
    || err "this build must run on an arm64 host; got $host_arch"

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

# The in-tree kernel build produces modules with release string "<KVER>-vyos"
# (LOCALVERSION=-vyos from build-kernel.sh — chosen so the kernel is a
# drop-in replacement for VyOS's own kernel). The OOT modules must match
# that exact release string; the kernel tree itself encodes that via its
# own CONFIG_LOCALVERSION / localversion* files.
KRELEASE="${KVER}-vyos"

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
dim "   compiler:     $(gcc --version 2>/dev/null | head -1)"

rm -rf "$SRC_ROOT" "$BUILD_ROOT" "$STAGING"
mkdir -p "$SRC_ROOT" "$BUILD_ROOT" "$STAGING"

# ── Precondition: NXP linux-lsdk FMan SDK layer present? ────────────────
#
# The ASK OOT modules (cdx in particular) include
#   $(srctree)/drivers/net/ethernet/freescale/sdk_fman/ncsw_config.mk
# which is part of the proprietary NXP linux-lsdk FMan SDK subtree —
# hundreds of files NXP historically shipped as a separate layer on top
# of mainline. The 6.6 reference tree (mihakralj/ask-ls1046a-6.6) only
# installs a 4-file stub of sdk_fman/ alongside sdk_dpaa/ and does NOT
# include ncsw_config.mk. Without that file the cdx/fci/auto_bridge
# modules cannot be compiled.
#
# The in-kernel fast-path hooks (from 003-ask-kernel-hooks.patch) ARE
# built into the kernel image .deb we already produce, so the hook
# surface is present. What's missing is the OOT driver that plugs into
# those hooks — and that driver requires the NXP SDK FMan layer.
#
# If ncsw_config.mk is absent we skip this build cleanly rather than
# failing. To enable, the user must layer the NXP linux-lsdk sdk_fman/
# subtree into release/patches/kernel/sdk-sources/ and re-run.
NCSW_MK="$KDIR/drivers/net/ethernet/freescale/sdk_fman/ncsw_config.mk"
if [[ ! -f "$NCSW_MK" ]]; then
    warn "NXP linux-lsdk FMan SDK not present in kernel tree"
    dim "   expected: $NCSW_MK"
    dim "   this file is provided by the NXP linux-lsdk sdk_fman subtree,"
    dim "   which the 6.6 reference repo does not bundle. The in-kernel"
    dim "   fast-path hooks are still compiled in — only the OOT drivers"
    dim "   (cdx/fci/auto_bridge) are skipped."
    dim ""
    dim "   to enable ASK OOT modules, layer the NXP linux-lsdk sdk_fman/"
    dim "   subtree into release/patches/kernel/sdk-sources/ so that"
    dim "   ncsw_config.mk is installed by apply-to-tree.sh"
    # Use a distinct soft-skip exit code so run-pipeline.sh can
    # tolerate this case via run_step_softfail 77 while still
    # hard-failing on any other non-zero exit (real build errors).
    info "ASK OOT modules: SKIPPED (SDK FMan layer absent) — not a build failure"
    exit 77
fi

# Extract the three module trees from the bare mirror
begin_group "extract ASK sources"
for dir in cdx fci auto_bridge; do
    git --git-dir="$MIRROR" archive "$ASK_SHA" -- "$dir" \
        | tar -C "$SRC_ROOT" -x
    [[ -d "$SRC_ROOT/$dir" ]] || err "extraction failed for $dir"
    ok "extracted $dir ($(find "$SRC_ROOT/$dir" -name '*.c' | wc -l) .c files)"
done
end_group

# ── Apply ASK-modules patches (6.6 compat, Mono-specific fixes) ─────────
#
# Patches in release/patches/ask-modules/*.patch are applied in sort order
# against $SRC_ROOT (the extracted cdx/fci/auto_bridge tree). These patches
# track changes that the 6.6 reference repo (mihakralj/ask-ls1046a-6.6)
# made on top of the original we-are-mono/ASK sources — e.g. 6.6 API drift
# (const struct ctl_table), WiFi-offload disablement, defensive NULL
# checks, crash-safe userspace pointer handling in dpa_cfg.c.
#
# Rationale for applying at build time (rather than pre-patching the git
# archive): the upstream ASK tree is pulled via `git archive` from the
# bare mirror and is intentionally pristine — these patches are OUR
# downstream deltas, versioned in this repo so they can be reviewed
# independently of the upstream ASK SHA pin.
PATCH_DIR="$REPO_ROOT/release/patches/ask-modules"
if [[ -d "$PATCH_DIR" ]]; then
    shopt -s nullglob
    ask_patches=( "$PATCH_DIR"/*.patch )
    shopt -u nullglob
    if (( ${#ask_patches[@]} > 0 )); then
        begin_group "apply ASK-modules patches (${#ask_patches[@]} file(s))"
        for p in "${ask_patches[@]}"; do
            info "  applying $(basename "$p")"
            if ! (cd "$SRC_ROOT" && git apply --whitespace=nowarn "$p"); then
                err "failed to apply $(basename "$p")"
            fi
            ok "    applied $(basename "$p")"
        done
        end_group
    else
        dim "no patches in $PATCH_DIR — skipping patch-apply step"
    fi
else
    dim "$PATCH_DIR does not exist — skipping patch-apply step"
fi

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
    "BOARD_ARCH=$ARCH"
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
                -j"$(nproc_any)" all 2>&1
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
    strip --strip-unneeded "$BUILD_ROOT/${name}.ko"
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
# auto_bridge requires kernel-side LSDK-specific patches (brevent_fdb_update,
# sk_buff::abm_ff, register_brevent_notifier) not present in mainline 6.6.135.
# Build it as best-effort: log a warning and continue if it fails so the
# package still ships cdx+fci.
AB_OK=1
if ! ( build_mod auto_bridge ); then
    AB_OK=0
    warn "auto_bridge build failed; shipping cdx+fci only"
fi
MODS=(cdx fci)
(( AB_OK )) && MODS+=(auto_bridge)
end_group

# ── Verify vermagic ─────────────────────────────────────────────────────
begin_group "verify module vermagic matches kernel"
vermagic_ok=1
for m in "${MODS[@]}"; do
    vm=$(objdump -t "$BUILD_ROOT/${m}.ko" 2>/dev/null \
        | grep -oE '__module_depends|__versions' | head -1 || true)
    # Extract vermagic string from the .modinfo section
    vm=$(objcopy --dump-section .modinfo=/dev/stdout "$BUILD_ROOT/${m}.ko" 2>/dev/null \
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
for m in "${MODS[@]}"; do cp -v "$BUILD_ROOT/${m}.ko" "$MOD_DIR/" >/dev/null; done

mkdir -p "$STAGING/etc/modules-load.d"
{
    echo "# Load NXP ASK fast-path modules at boot."
    echo "# Order matters: cdx provides symbols consumed by fci (and auto_bridge)."
    for m in "${MODS[@]}"; do echo "$m"; done
} > "$STAGING/etc/modules-load.d/ask.conf"

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
for m in "${MODS[@]}"; do
    printf '     /lib/modules/%s/extra/ask/%s.ko (%s)\n' \
        "$KRELEASE" "$m" "$(du -h "$BUILD_ROOT/${m}.ko" | cut -f1)"
done