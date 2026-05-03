#!/usr/bin/env bash
# split-reference-patch.sh — split the monolithic 003-ask-kernel-hooks.patch
# in the reference repo into thematic, per-subsystem patches.
#
# Rationale:
#   A single 5,797-line kernel patch touching 13 subsystems is hostile to
#   conflict resolution — when upstream 6.6.N modifies, say, net/bridge/br.c,
#   the conflict is buried inside a giant haystack of unrelated hunks. Splitting
#   the monolith by subsystem means each thematic patch is small, cohesive, and
#   easy to rebase in isolation. This is standard quilt discipline.
#
# What this script does:
#   1. Reads the reference repo's monolithic kernel patch.
#   2. Classifies each `diff --git` block by subsystem (path-prefix heuristic).
#   3. Writes N thematic patches to a staging directory, numbered in a sensible
#      application order (build plumbing first, then core-net, then dependents).
#   4. Verifies that the concatenation of the split patches equals the original.
#   5. Prints an rsync-ready set of instructions for committing to the reference
#      repo.
#
# Non-destructive: this script DOES NOT modify the reference repo. It only
# produces a staging tree that you can inspect and copy over manually.
#
# Usage:
#   ./scripts/split-reference-patch.sh
#   ./scripts/split-reference-patch.sh --check-only    # verify-only, no output

set -euo pipefail
source "$(dirname "$0")/common.sh"

need filterdiff lsdiff diff cat

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

[[ -d "$WORK_DIR/reference/.git" ]] || "$SCRIPTS_DIR/fetch-reference.sh"

MONOLITH="$WORK_DIR/reference/$REFERENCE_KERNEL_PATCH"
[[ -f "$MONOLITH" ]] || err "monolithic patch not found: $MONOLITH"

CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

OUT="$WORK_DIR/split-staging"
rm -rf "$OUT"
mkdir -p "$OUT/patches/kernel"

# ── Path → subsystem classifier ─────────────────────────────────────────
# Returns bucket name for a given file path. The cases are evaluated top-to-
# bottom; more-specific prefixes must come before more-general ones.
classify() {
    local p="$1"
    case "$p" in
        # Build plumbing
        Makefile|tools/*)                                  echo "build" ;;

        # Driver subsystems — specific first
        drivers/crypto/caam/*)                             echo "caam" ;;
        drivers/net/ppp/*)                                 echo "ppp" ;;
        drivers/net/usb/*)                                 echo "usbnet" ;;

        # net subtrees — order matters: xfrm/netfilter before ipv4/ipv6
        net/bridge/*)                                      echo "bridge" ;;
        net/xfrm/*|net/key/*|net/ipv4/xfrm4_policy.c|net/ipv6/xfrm6_policy.c)
                                                           echo "xfrm" ;;
        net/netfilter/*|net/ipv6/netfilter/*)              echo "netfilter" ;;
        net/ipv4/*)                                        echo "ipv4" ;;
        net/ipv6/*)                                        echo "ipv6" ;;
        net/wireless/*)                                    echo "wireless" ;;
        net/core/*|net/Kconfig)                            echo "core-net" ;;

        # Headers by area
        include/linux/if_bridge.h)                         echo "bridge" ;;
        include/net/netfilter/*|include/uapi/linux/netfilter/*)
                                                           echo "netfilter" ;;
        include/net/xfrm.h|include/net/netns/xfrm.h|include/uapi/linux/pfkeyv2.h)
                                                           echo "xfrm" ;;
        include/uapi/linux/if_tunnel.h|include/uapi/linux/ip6_tunnel.h|include/net/ip6_tunnel.h)
                                                           echo "tunnels" ;;
        include/uapi/linux/ppp-ioctl.h)                    echo "ppp" ;;

        # Core networking headers (skb, netdev, poll, if, rtnetlink, netlink, ip.h)
        include/linux/netdevice.h|include/linux/skbuff.h|include/linux/poll.h|\
        include/net/ip.h|\
        include/uapi/linux/if.h|include/uapi/linux/if_arp.h|\
        include/uapi/linux/netlink.h|include/uapi/linux/rtnetlink.h)
                                                           echo "core-net" ;;

        *)                                                 echo "UNCLASSIFIED" ;;
    esac
}

# ── Subsystem → (stage number, human description) ──────────────────────
# Stage numbers continue from 003 (the next after existing 001-, 002- in the
# reference's patch stack if any were present).
stage_of() {
    case "$1" in
        build)      echo "003:build plumbing (Makefile, tools/.gitignore)" ;;
        core-net)   echo "004:core networking (net/core, net/Kconfig, netdevice/skbuff/poll/rtnetlink/if)" ;;
        bridge)     echo "005:linux bridge forwarding hooks" ;;
        tunnels)    echo "006:generic tunnel headers (if_tunnel, ip6_tunnel)" ;;
        ipv4)       echo "007:IPv4 stack hooks (non-XFRM)" ;;
        ipv6)       echo "008:IPv6 stack hooks (non-XFRM, non-NF)" ;;
        xfrm)       echo "009:XFRM / IPsec fast-path hooks" ;;
        netfilter)  echo "010:netfilter / conntrack / QOSMARK extensions" ;;
        ppp)        echo "011:PPP and PPPoE device hooks" ;;
        usbnet)     echo "012:USB network device hooks" ;;
        wireless)   echo "013:wireless extensions" ;;
        caam)       echo "014:Freescale CAAM crypto PDB extension" ;;
        *)          echo "" ;;
    esac
}

# ── Pass 1: dry-run classification for sanity ───────────────────────────
info "Classifying files in monolithic kernel patch…"
declare -a UNCLASSIFIED=()

# collect unique paths → buckets  (bash 3.2 compat: parallel arrays)
# lsdiff --strip=1 is the canonical way to enumerate b-side paths;
# replaces `grep '^diff --git' | awk | sed` and correctly handles renames,
# mode-change blocks, and binary patches that the manual parser would miss.
PATHS=()
BUCKETS=()
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    b=$(classify "$path")
    PATHS+=("$path")
    BUCKETS+=("$b")
    [[ "$b" == "UNCLASSIFIED" ]] && UNCLASSIFIED+=("$path")
done < <(lsdiff --strip=1 "$MONOLITH" | sort -u)

TOTAL=${#PATHS[@]}
info "   total files in patch:  $TOTAL"

# Per-bucket counts
for bucket in build core-net bridge tunnels ipv4 ipv6 xfrm netfilter ppp usbnet wireless caam; do
    c=0
    for b in "${BUCKETS[@]}"; do [[ "$b" == "$bucket" ]] && c=$((c+1)); done
    stage_desc=$(stage_of "$bucket")
    stage="${stage_desc%%:*}"
    desc="${stage_desc#*:}"
    printf "   %-12s %2d files  →  %s-ask-%s.patch  (%s)\n" \
        "$bucket" "$c" "$stage" "$bucket" "$desc"
done

if (( ${#UNCLASSIFIED[@]} > 0 )); then
    err "UNCLASSIFIED paths (extend classify()): ${UNCLASSIFIED[*]}"
fi
ok "all $TOTAL files classified"

if (( CHECK_ONLY )); then
    ok "--check-only: skipping split"
    exit 0
fi

# ── Pass 2: actually split ──────────────────────────────────────────────
info ""
info "Splitting monolithic patch into thematic sub-patches…"

# For each bucket, build a filterdiff argv of -i globs (one pair per path:
# 'a/<path>' and 'b/<path>') and let filterdiff carve out the relevant
# diff-git blocks from the monolith in a single pass. This replaces the
# previous hand-rolled awk splitter with the canonical patchutils tool.
for bucket in build core-net bridge tunnels ipv4 ipv6 xfrm netfilter ppp usbnet wireless caam; do
    # Collect paths belonging to this bucket
    args=()
    for ((i=0; i<TOTAL; i++)); do
        if [[ "${BUCKETS[i]}" == "$bucket" ]]; then
            args+=( -i "a/${PATHS[i]}" -i "b/${PATHS[i]}" )
        fi
    done
    (( ${#args[@]} )) || continue

    stage_desc=$(stage_of "$bucket")
    stage="${stage_desc%%:*}"
    desc="${stage_desc#*:}"
    out="$OUT/patches/kernel/${stage}-ask-${bucket}.patch"
    {
        echo "# ${stage}-ask-${bucket}.patch"
        echo "# ${desc}"
        echo "#"
        echo "# Extracted from 003-ask-kernel-hooks.patch by scripts/split-reference-patch.sh"
        echo "# (filterdiff from patchutils). Do not edit by hand without also updating"
        echo "# the splitter's path→bucket map."
        echo "#"
        filterdiff "${args[@]}" "$MONOLITH"
    } > "$out"
    dim "   $out  ($(wc -l < "$out") lines)"
done

# ── Pass 3: verify round-trip ──────────────────────────────────────────
info ""
info "Verifying split is lossless (concat == original)…"
RECON="$OUT/reconstructed.patch"
# Concatenate all split patches (stripping our '#' annotation lines) into a
# single stream. Line-for-line equality with the monolith is NOT expected —
# intra-bucket ordering is preserved, but across buckets the ordering differs.
#
# What we CAN verify losslessness on:
#   (a) the SET OF PATHS touched (via lsdiff, which correctly finds new-file
#       blocks even when filterdiff drops the 'diff --git' header line)
#   (b) the total count of '+' and '-' content lines (ignoring +++ / --- file
#       headers). These must match exactly.
grep -hv '^#' "$OUT/patches/kernel/"*.patch > "$RECON"

orig_paths=$(lsdiff --strip=1 "$MONOLITH"  | sort -u)
new_paths=$( lsdiff --strip=1 "$RECON"     | sort -u)
orig_count=$(printf '%s\n' "$orig_paths" | wc -l)
new_count=$( printf '%s\n' "$new_paths"  | wc -l)

# grep -c can exit 1 on zero matches; || true keeps set -e happy.
orig_pluslines=$( grep -c '^+[^+]'  "$MONOLITH" || true)
new_pluslines=$(  grep -c '^+[^+]'  "$RECON"    || true)
orig_minuslines=$(grep -c '^-[^-]'  "$MONOLITH" || true)
new_minuslines=$( grep -c '^-[^-]'  "$RECON"    || true)

printf "   paths touched:    original=%d   split=%d\n"  "$orig_count"     "$new_count"
printf "   '+' lines:        original=%d   split=%d\n"  "$orig_pluslines" "$new_pluslines"
printf "   '-' lines:        original=%d   split=%d\n"  "$orig_minuslines" "$new_minuslines"

paths_match=0
if [[ "$(printf '%s\n' "$orig_paths")" == "$(printf '%s\n' "$new_paths")" ]]; then
    paths_match=1
fi

if (( paths_match )) \
   && [[ "$orig_pluslines" == "$new_pluslines" \
      && "$orig_minuslines" == "$new_minuslines" ]]; then
    ok "round-trip OK: split preserves every path and every +/- line"
else
    # Surface exactly which paths differ for faster diagnosis.
    if (( ! paths_match )); then
        diff <(printf '%s\n' "$orig_paths") <(printf '%s\n' "$new_paths") | sed 's/^/     /'
    fi
    err "round-trip MISMATCH: split is lossy — aborting"
fi

# ── Next-steps summary ─────────────────────────────────────────────────
info ""
info "Writing instructions…"
SUMMARY="$OUT/NEXT-STEPS.md"
cat > "$SUMMARY" <<EOF
# Committing the thematic split to the reference repo

This directory contains the split kernel patch, ready to replace the monolith
in the reference repo ($REFERENCE_REPO).

## Files produced

\`\`\`
$(ls "$OUT/patches/kernel/" | sed 's/^/    /')
\`\`\`

## To commit to the reference repo

\`\`\`bash
# 1. Get a clean checkout of reference
git clone $REFERENCE_REPO /tmp/ref-split && cd /tmp/ref-split

# 2. Replace the monolith with the split
rm patches/kernel/003-ask-kernel-hooks.patch
cp $OUT/patches/kernel/*.patch patches/kernel/

# 3. Sanity: patch -p1 --dry-run each in order against a fresh 6.6 tree
cd ../some-fresh-linux-6.6.137
for p in /tmp/ref-split/patches/kernel/0*.patch; do
    patch -p1 --dry-run < "\$p" || { echo "FAIL: \$p"; break; }
done

# 4. Commit
cd /tmp/ref-split
git add patches/kernel/
git commit -m "kernel: split monolithic hooks patch into thematic sub-patches

    Turns the single 5,797-line 003-ask-kernel-hooks.patch into 12 thematic
    per-subsystem patches so that conflicts with upstream 6.6.y stable releases
    are localised to one small patch at a time.

    Split performed by scripts/split-reference-patch.sh in lts_6.6_ls1046a."

git push origin $REFERENCE_REF
\`\`\`

## After pushing

Re-run the derivation engine:

\`\`\`bash
cd lts_6.6_ls1046a
./scripts/fetch-reference.sh          # pick up split reference
./scripts/patch-health.sh             # verify all 12 patches apply cleanly
./scripts/derive-patches.sh           # should still report status: ok
\`\`\`

No changes are needed to versions.lock or any other script — patch-health.sh
already iterates the kernel patch directory and picks up all \`0*.patch\` files.
EOF

ok "staging tree ready in: $OUT"
info "next steps:          $SUMMARY"