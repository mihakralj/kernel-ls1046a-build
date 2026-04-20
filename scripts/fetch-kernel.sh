#!/usr/bin/env bash
# fetch-kernel.sh — download a linux-6.6.N stable tarball and extract it
#
# Usage:
#   ./scripts/fetch-kernel.sh              # auto-picks latest 6.6.y
#   ./scripts/fetch-kernel.sh 6.6.123      # pins a specific version
#
# Side effects:
#   work/linux-<VERSION>.tar.xz         (cached; not re-downloaded if present)
#   work/linux-<VERSION>/                (extracted source tree)
#   work/.kernel-version                 (contains "<VERSION>")

set -euo pipefail
source "$(dirname "$0")/common.sh"

need curl tar jq

# Priority order for the target kernel version:
#   1. positional arg ($1)                  — explicit CLI override
#   2. KERNEL_VERSION env / versions.lock    — persistent pin
#   3. kernel.org latest 6.6.y               — floating
if [[ -f "$REPO_ROOT/versions.lock" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/versions.lock"
fi

VERSION="${1:-${KERNEL_VERSION:-}}"
if [[ -z "$VERSION" ]]; then
    info "Resolving latest linux-6.6.y from kernel.org…"
    VERSION="$(latest_6_6_y)"
    [[ -n "$VERSION" ]] || err "Could not resolve latest 6.6.y version"
else
    dim "Using pinned kernel version: $VERSION"
fi

# Validate shape
[[ "$VERSION" =~ ^6\.6\.[0-9]+$ ]] || err "invalid version: '$VERSION' (expected 6.6.N)"

ok "Target kernel: linux-${VERSION}"

TARBALL="${WORK_DIR}/linux-${VERSION}.tar.xz"
SIGFILE="${WORK_DIR}/linux-${VERSION}.tar.sign"
SRCDIR="${WORK_DIR}/linux-${VERSION}"
URL_BASE="https://cdn.kernel.org/pub/linux/kernel/v6.x"

# ── Download ────────────────────────────────────────────────────────────
if [[ -f "$TARBALL" ]]; then
    dim "tarball cached: $TARBALL"
else
    info "Downloading ${URL_BASE}/linux-${VERSION}.tar.xz"
    curl -fL --progress-bar -o "$TARBALL" "${URL_BASE}/linux-${VERSION}.tar.xz" \
        || err "download failed"
    ok "downloaded $(du -h "$TARBALL" | cut -f1)"
fi

# Optional signature (best-effort; only check if gpg + key available)
if command -v gpg >/dev/null 2>&1; then
    if [[ ! -f "$SIGFILE" ]]; then
        curl -fsL -o "$SIGFILE" "${URL_BASE}/linux-${VERSION}.tar.sign" 2>/dev/null || true
    fi
    # Note: we do NOT enforce signature verification here; just make the file
    # available for anyone who wants to verify manually.
fi

# ── Extract ─────────────────────────────────────────────────────────────
if [[ -d "$SRCDIR" && -f "$SRCDIR/Makefile" ]]; then
    dim "source tree present: $SRCDIR"
else
    info "Extracting tarball…"
    rm -rf "$SRCDIR"
    tar -C "$WORK_DIR" -xJf "$TARBALL"
    [[ -f "$SRCDIR/Makefile" ]] || err "extract produced no Makefile at $SRCDIR"
    ok "extracted to $SRCDIR"
fi

# ── Record version (legacy marker, kept for backward compat) ────────────
echo "$VERSION" > "$WORK_DIR/.kernel-version"

# ── Normalised state: report old vs new ─────────────────────────────────
# Identity for the kernel is the version string. fetch_state_write returns
# 0 on unchanged, 10 on new/changed; we propagate that as our own exit code.
set +e
fetch_state_write "kernel" "$VERSION"
STATE_RC=$?
set -e

# ── Summary ─────────────────────────────────────────────────────────────
KVER=$(awk '/^VERSION/{v=$3} /^PATCHLEVEL/{p=$3} /^SUBLEVEL/{s=$3} END{print v"."p"."s}' \
    "$SRCDIR/Makefile")
[[ "$KVER" == "$VERSION" ]] || warn "Makefile reports $KVER, expected $VERSION"

ok "kernel ready: ${SRCDIR} (${KVER})"
exit "$STATE_RC"
