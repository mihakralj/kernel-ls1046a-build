#!/usr/bin/env bash
# build-ask-ppp.sh — cross-compile patched ppp and rp-pppoe Debian source
# packages for arm64 with the NXP ASK PPPoE fast-path patches applied.
#
# This single script covers Phase 5 (both packages). Each sub-build is
# independent: if ppp fails, rp-pppoe is still attempted, and vice versa.
# The final exit code is 0 if at least one package built and none of the
# attempted packages failed after applying.
#
# The patches are small source-level modifications of existing files:
#   patches/ppp/01-nxp-ask-ifindex.patch       (44 lines, pppd/ipcp.c)
#   patches/rp-pppoe/01-nxp-ask-cmm-relay.patch (307 lines, src/Makefile.in + src/relay.c)
#
# Prerequisites:
#   - work/upstream.git/ exists (scripts/fetch-upstream.sh ran)
#   - Host has the Debian cross-build toolchain, same set as
#     build-ask-iptables.sh: dpkg-dev, debhelper, devscripts, quilt,
#     dpkg-cross, gcc-aarch64-linux-gnu, and deb-src enabled.
#   - arm64 registered as a foreign architecture (dpkg --add-architecture arm64).
#
# Pipeline position: after build-ask-iptables.sh (independent; runs as
# step 8b layer 3 under --ask-extras).
#
# Usage:
#   ./scripts/build-ask-ppp.sh
#   ./scripts/build-ask-ppp.sh --arch arm64
#   ./scripts/build-ask-ppp.sh --only ppp         # build only ppp
#   ./scripts/build-ask-ppp.sh --only rp-pppoe    # build only rp-pppoe
#
# Outputs:
#   work/build/ppp_<ver>+ask1_arm64.deb
#   work/build/pppoe_<ver>+ask1_arm64.deb     (from rp-pppoe source)
#   work/build/ppp-dev_<ver>+ask1_all.deb, etc.
#   work/ask-ppp/{ppp,rp-pppoe}/build.log
#
# Exit codes:
#   0  all requested packages built (or at least one built, none failed)
#   1  missing prerequisites, all attempted packages failed
#   2  a patch failed to apply

set -euo pipefail
source "$(dirname "$0")/common.sh"

# ── Config ──────────────────────────────────────────────────────────────
DIST="${DIST:-bookworm}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
# Empty by default → native build (CI runs on an arm64 runner). Export
# CROSS_COMPILE=aarch64-linux-gnu- only if cross-building from an x86_64 host.
CROSS_COMPILE="${CROSS_COMPILE:-}"
REVISION_SUFFIX="${REVISION_SUFFIX:-+ask1}"
ONLY=""

while (( $# )); do
    case "$1" in
        --dist)    DIST="${2:?--dist needs arg}";          shift 2 ;;
        --arch)    TARGET_ARCH="${2:?--arch needs arg}";   shift 2 ;;
        --cross)   CROSS_COMPILE="${2:?--cross needs arg}"; shift 2 ;;
        --only)    ONLY="${2:?--only needs arg}";          shift 2 ;;
        -h|--help) sed -n '1,42p' "$0"; exit 0 ;;
        *)         err "unknown arg: $1" ;;
    esac
done

need apt-get dpkg-source dpkg-buildpackage git patch

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 \
    || err "compiler missing: ${CROSS_COMPILE:-native }gcc"

# ── Resolve upstream commit ────────────────────────────────────────────
MIRROR="$WORK_DIR/upstream.git"
[[ -d "$MIRROR" ]] || err "upstream mirror missing; run fetch-upstream.sh first"

ASK_SHA="${UPSTREAM_TARGET:-${UPSTREAM_BASELINE:?}}"
ASK_SHA=$(git --git-dir="$MIRROR" rev-parse "$ASK_SHA^{commit}" 2>/dev/null) \
    || err "cannot resolve ASK commit: ${UPSTREAM_TARGET:-$UPSTREAM_BASELINE}"

# ── Shared workspace ───────────────────────────────────────────────────
WS="$WORK_DIR/ask-ppp"
OUT_DIR="$WORK_DIR/build"
rm -rf "$WS"
mkdir -p "$WS" "$OUT_DIR"

export DEBEMAIL="${DEBEMAIL:-ci@localhost}"
export DEBFULLNAME="${DEBFULLNAME:-ASK LTS 6.6 Autobuilder}"

info "building patched ppp + rp-pppoe (Debian source rebuilds)"
dim "   patch commit:   ${ASK_SHA:0:12}"
dim "   target arch:    $TARGET_ARCH"
dim "   cross:          ${CROSS_COMPILE}gcc"
dim "   revision tag:   $REVISION_SUFFIX"

# ── Worker: build one source package ────────────────────────────────────
#
# Args:
#   $1  src_pkg       Debian source package name (e.g. "ppp", "rp-pppoe")
#   $2  patch_subpath upstream path (e.g. "patches/ppp/01-nxp-ask-ifindex.patch")
#
# Sets: BUILT_<pkg>=<path-to-first-produced-deb>  (on success)
#       FAIL_REASON_<pkg>=<short reason>          (on failure)
BUILT_SUMMARY=()
FAIL_SUMMARY=()

build_one() {
    local src_pkg="$1"
    local patch_subpath="$2"

    local sub="$WS/$src_pkg"
    local src_root="$sub/src"
    mkdir -p "$src_root"
    local patch_file="$sub/patch.diff"

    begin_group "build $src_pkg (+ASK patch)"

    # 1. Extract the patch
    if ! git --git-dir="$MIRROR" show "$ASK_SHA:$patch_subpath" > "$patch_file" 2>/dev/null; then
        warn "  cannot extract $patch_subpath at $ASK_SHA"
        FAIL_SUMMARY+=("$src_pkg: patch extraction failed")
        end_group
        return 1
    fi
    ok "  extracted patch ($(wc -l < "$patch_file") lines)"

    # 2. Fetch Debian source
    info "  apt-get source $src_pkg"
    if ! (cd "$src_root" && apt-get source "$src_pkg" > "$sub/apt-source.log" 2>&1); then
        warn "  apt-get source $src_pkg failed"
        tail -20 "$sub/apt-source.log" >&2 || true
        FAIL_SUMMARY+=("$src_pkg: apt-get source failed")
        end_group
        return 1
    fi

    local src_dir
    src_dir=$(find "$src_root" -mindepth 1 -maxdepth 1 -type d -name "${src_pkg}-*" | head -1)
    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        warn "  no ${src_pkg}-* directory after apt-get source"
        FAIL_SUMMARY+=("$src_pkg: source tree not found")
        end_group
        return 1
    fi
    local upstream_ver
    upstream_ver=$(basename "$src_dir" | sed -E "s/^${src_pkg}-//")
    ok "  fetched $src_pkg $upstream_ver"

    # 3. Dry-run the patch for clear diagnostics
    if ! (cd "$src_dir" && patch -p1 --dry-run --quiet < "$patch_file"); then
        warn "  $src_pkg: patch does not apply cleanly"
        (cd "$src_dir" && patch -p1 --dry-run < "$patch_file") 2>&1 | tail -30 >&2
        FAIL_SUMMARY+=("$src_pkg: patch rejected by dry-run")
        end_group
        return 2
    fi

    # 4. Apply and register
    (cd "$src_dir" && patch -p1 --quiet < "$patch_file") \
        || { FAIL_SUMMARY+=("$src_pkg: patch apply failed post-dry-run"); end_group; return 1; }
    if [[ -f "$src_dir/debian/source/format" ]] \
        && grep -q '3.0 (quilt)' "$src_dir/debian/source/format"; then
        mkdir -p "$src_dir/debian/patches"
        cp "$patch_file" "$src_dir/debian/patches/0999-ask.patch"
        touch "$src_dir/debian/patches/series"
        grep -qx '0999-ask.patch' "$src_dir/debian/patches/series" 2>/dev/null \
            || echo '0999-ask.patch' >> "$src_dir/debian/patches/series"
    fi
    ok "  patch applied"

    # 5. Changelog bump
    local new_ver="${upstream_ver}${REVISION_SUFFIX}"
    (
        cd "$src_dir"
        if command -v dch >/dev/null 2>&1; then
            dch --distribution "$DIST" --newversion "$new_ver" \
                "Apply NXP ASK patch from ${ASK_SHA:0:12} ($(basename "$patch_subpath"))."
        else
            {
                printf '%s (%s) %s; urgency=medium\n\n' "$src_pkg" "$new_ver" "$DIST"
                printf '  * Apply NXP ASK patch from %s (%s).\n\n' \
                    "${ASK_SHA:0:12}" "$(basename "$patch_subpath")"
                printf ' -- %s <%s>  %s\n\n' \
                    "$DEBFULLNAME" "$DEBEMAIL" "$(date -R)"
                cat debian/changelog
            } > debian/changelog.new
            mv debian/changelog.new debian/changelog
        fi
    )
    ok "  version → $new_ver"

    # `dch --newversion` renames the working directory from
    # <pkg>-<ver> to <pkg>-<new_ver>. Re-resolve src_dir so the
    # subsequent build runs in the correct place.
    local new_src_dir
    new_src_dir=$(find "$src_root" -mindepth 1 -maxdepth 1 -type d \
        -name "${src_pkg}-${new_ver}" | head -1)
    if [[ -n "$new_src_dir" && -d "$new_src_dir" ]]; then
        src_dir="$new_src_dir"
    elif [[ ! -d "$src_dir" ]]; then
        # Fallback: pick the only remaining ${src_pkg}-* dir
        src_dir=$(find "$src_root" -mindepth 1 -maxdepth 1 -type d \
            -name "${src_pkg}-*" | head -1)
    fi
    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        warn "  $src_pkg: source dir vanished after changelog bump"
        FAIL_SUMMARY+=("$src_pkg: src dir lost post-dch")
        end_group
        return 1
    fi

    # 6. Build (native if host arch == target, cross otherwise)
    local build_log="$sub/build.log"
    info "  building for $TARGET_ARCH (log: $build_log)"
    set +e
    (
        cd "$src_dir"
        export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc_any)"
        local build_host_arch
        build_host_arch=$(dpkg --print-architecture)
        local hostarch_args=()
        if [[ "$build_host_arch" != "$TARGET_ARCH" ]]; then
            hostarch_args+=( --host-arch "$TARGET_ARCH" )
        fi
        dpkg-buildpackage \
            "${hostarch_args[@]}" \
            --build=binary \
            -uc -us 2>&1
    ) > "$build_log"
    local rc=$?
    set -e

    if (( rc != 0 )); then
        warn "  $src_pkg: dpkg-buildpackage failed (exit $rc); last 40 lines:"
        tail -40 "$build_log" >&2
        FAIL_SUMMARY+=("$src_pkg: dpkg-buildpackage exit $rc")
        end_group
        return 1
    fi

    # 7. Collect artefacts
    shopt -s nullglob
    local produced=( "$src_root"/*"${REVISION_SUFFIX}"*"_${TARGET_ARCH}.deb"
                     "$src_root"/*"${REVISION_SUFFIX}"*"_all.deb"
                     "$src_root"/*"${REVISION_SUFFIX}"*".changes"
                     "$src_root"/*"${REVISION_SUFFIX}"*".buildinfo" )
    shopt -u nullglob

    if (( ${#produced[@]} == 0 )); then
        warn "  $src_pkg: build completed but no .debs found"
        FAIL_SUMMARY+=("$src_pkg: no .debs produced")
        end_group
        return 1
    fi

    local debs_count=0
    for f in "${produced[@]}"; do
        cp -v "$f" "$OUT_DIR/" | sed 's|^|   |'
        [[ "$f" == *.deb ]] && debs_count=$((debs_count+1))
    done
    ok "  $src_pkg: built $debs_count .deb(s), version $new_ver"
    BUILT_SUMMARY+=("$src_pkg $new_ver ($debs_count .deb)")
    end_group
    return 0
}

# ── Drive both builds ──────────────────────────────────────────────────
PKGS=()
[[ -z "$ONLY" || "$ONLY" == "ppp"      ]] && PKGS+=( "ppp:patches/ppp/01-nxp-ask-ifindex.patch" )
[[ -z "$ONLY" || "$ONLY" == "rp-pppoe" ]] && PKGS+=( "rp-pppoe:patches/rp-pppoe/01-nxp-ask-cmm-relay.patch" )

if (( ${#PKGS[@]} == 0 )); then
    err "nothing to build; --only must be 'ppp' or 'rp-pppoe'"
fi

ANY_OK=0
ANY_FAIL=0
for entry in "${PKGS[@]}"; do
    pkg="${entry%%:*}"
    patch="${entry#*:}"
    if build_one "$pkg" "$patch"; then
        ANY_OK=1
    else
        ANY_FAIL=1
    fi
done

# ── Summary ─────────────────────────────────────────────────────────────
echo
info "── ask-ppp build summary ──"
printf '   patch commit:   %s\n' "${ASK_SHA:0:12}"
printf '   target arch:    %s\n' "$TARGET_ARCH"
if (( ${#BUILT_SUMMARY[@]} )); then
    printf '   built:\n'
    for s in "${BUILT_SUMMARY[@]}"; do printf '     ✓ %s\n' "$s"; done
fi
if (( ${#FAIL_SUMMARY[@]} )); then
    printf '   failed:\n'
    for s in "${FAIL_SUMMARY[@]}"; do printf '     ✗ %s\n' "$s"; done
fi

# Exit code policy:
#   All attempted succeeded     → 0
#   Mixed                       → 0 (partial OK; don't block the rest of the pipeline)
#   All failed                  → 1
#   Any patch rejected dry-run  → 2 (with priority over 1 so CI summary is informative)
if (( ANY_OK && ! ANY_FAIL )); then
    exit 0
fi
if (( ANY_OK && ANY_FAIL )); then
    warn "partial success: some packages failed but at least one built"
    exit 0
fi
# all failed → pick specific exit code
if printf '%s\n' "${FAIL_SUMMARY[@]}" | grep -q 'patch rejected'; then
    exit 2
fi
exit 1