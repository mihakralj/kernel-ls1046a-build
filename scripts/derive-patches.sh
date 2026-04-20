#!/usr/bin/env bash
# derive-patches.sh — reference-assisted re-derivation of 6.6 ASK patches
#
# Strategy (honest version):
#   Simple "diff-of-diffs + patch -p1" does NOT work, because upstream's
#   monolithic 17,900-line patch and reference's split 5,797-line patch
#   use totally different coordinate systems — line numbers in one do not
#   map to the other. We learned this the hard way.
#
#   What this script DOES do, reliably:
#     1. Fetch upstream@BASELINE and upstream@TARGET kernel patches.
#     2. Compute the upstream delta (diff-of-diffs) — informational.
#     3. Split both upstream patches AND the reference patch into one
#        file-per-source-file chunk.
#     4. Identify the set of source files whose upstream coverage changed
#        between BASELINE and TARGET.
#     5. For each such file, write a reconciliation bundle to
#        work/derived/reconciliation/<path>/ containing:
#            upstream-baseline.chunk   — upstream hunks at BASELINE
#            upstream-target.chunk     — upstream hunks at TARGET
#            reference.chunk           — reference's 6.6-adapted hunks
#            upstream.diff             — delta between baseline/target chunks
#        …so a human (or later tool) can reconcile semantics.
#     6. Emit manifest.json with status:
#            ok              — no files drifted; reference is current
#            needs_review    — some files drifted; reconciliation bundles ready
#
#   The reference 6.6 kernel patch is copied through to work/derived/
#   unchanged. Builds off this copy will behave exactly like building off
#   the reference alone — which is correct until reconciliation is applied.
#
# Usage:  ./scripts/derive-patches.sh

set -euo pipefail
source "$(dirname "$0")/common.sh"

need git diff awk

[[ -f "$REPO_ROOT/versions.lock" ]] || err "versions.lock not found at $REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.lock"

[[ -d "$WORK_DIR/reference/.git" ]] || "$SCRIPTS_DIR/fetch-reference.sh"
[[ -d "$WORK_DIR/upstream.git"    ]] || "$SCRIPTS_DIR/fetch-upstream.sh"

REF_DIR="$WORK_DIR/reference"
MIRROR="$WORK_DIR/upstream.git"

if [[ -n "${UPSTREAM_TARGET:-}" ]]; then
    TARGET_SHA=$(git --git-dir="$MIRROR" rev-parse "${UPSTREAM_TARGET}^{commit}") \
        || err "UPSTREAM_TARGET '$UPSTREAM_TARGET' not found"
else
    TARGET_SHA=$(git --git-dir="$MIRROR" rev-parse "${UPSTREAM_BRANCH}^{commit}")
fi
BASELINE_SHA=$(git --git-dir="$MIRROR" rev-parse "${UPSTREAM_BASELINE}^{commit}") \
    || err "UPSTREAM_BASELINE '$UPSTREAM_BASELINE' not found in mirror"

REF_SHA=$(git -C "$REF_DIR" rev-parse HEAD)
ok "Reference:          ${REF_DIR} @ ${REF_SHA:0:12}"
ok "Upstream baseline:  ${BASELINE_SHA:0:12}  ($(git --git-dir="$MIRROR" log -1 --format=%s "$BASELINE_SHA" | head -c 60))"
ok "Upstream target:    ${TARGET_SHA:0:12}  ($(git --git-dir="$MIRROR" log -1 --format=%s "$TARGET_SHA" | head -c 60))"

OUT="$WORK_DIR/derived"
rm -rf "$OUT"
mkdir -p "$OUT/patches/kernel" "$OUT/reports" "$OUT/reconciliation"

# ── Step 1: Extract upstream monolithic patch at baseline and target ────
info ""
info "Step 1/5: Extracting upstream 6.12 kernel patch at both SHAs…"
UP_PATCH_B="$OUT/reports/upstream-patch-at-baseline.patch"
UP_PATCH_T="$OUT/reports/upstream-patch-at-target.patch"
git --git-dir="$MIRROR" show "${BASELINE_SHA}:${UPSTREAM_KERNEL_PATCH}" > "$UP_PATCH_B" 2>/dev/null \
    || err "upstream patch missing @ baseline"
git --git-dir="$MIRROR" show "${TARGET_SHA}:${UPSTREAM_KERNEL_PATCH}"   > "$UP_PATCH_T" 2>/dev/null \
    || err "upstream patch missing @ target"
dim "   baseline: $(wc -l < "$UP_PATCH_B") lines"
dim "   target:   $(wc -l < "$UP_PATCH_T") lines"

# ── Step 2: Upstream delta (for reporting only) ─────────────────────────
info ""
info "Step 2/5: Computing upstream delta (informational)…"
UPSTREAM_DELTA="$OUT/reports/upstream-delta.diff"
diff -u "$UP_PATCH_B" "$UP_PATCH_T" > "$UPSTREAM_DELTA" || true
DELTA_LINES=$(wc -l < "$UPSTREAM_DELTA")
ok "delta: $DELTA_LINES lines"

# Short-circuit no-op.
if [[ "$DELTA_LINES" -eq 0 ]]; then
    cp "$REF_DIR/$REFERENCE_KERNEL_PATCH"   "$OUT/patches/kernel/003-ask-kernel-hooks.patch"
    cp -r "$REF_DIR/$REFERENCE_SDK_SOURCES" "$OUT/patches/kernel/sdk-sources"
    cp "$REF_DIR/config/ask.config"         "$OUT/"
    STATUS="ok"
    DRIFTED_COUNT=0
fi

# ── Step 3: Split all three patches into per-file chunks ────────────────
if [[ "$DELTA_LINES" -ne 0 ]]; then
    info ""
    info "Step 3/5: Splitting patches into per-file chunks…"

    SPLIT_BASELINE="$OUT/reports/chunks-upstream-baseline"
    SPLIT_TARGET="$OUT/reports/chunks-upstream-target"
    SPLIT_REF="$OUT/reports/chunks-reference"
    mkdir -p "$SPLIT_BASELINE" "$SPLIT_TARGET" "$SPLIT_REF"

    # Split a unified patch file into per-file chunks keyed by the 'b/' path.
    # Writes "<outdir>/<sanitised-path>.chunk" and a manifest "<outdir>/_files".
    # Strips `index aaa..bbb` blob-SHA lines — these change with every upstream
    # kernel bump even when hunks are identical, and would otherwise flood the
    # drift detector with false positives.
    split_patch() {
        local infile="$1" outdir="$2"
        awk -v outdir="$outdir" '
            function flush() {
                if (path != "") {
                    safe = path
                    gsub(/[^A-Za-z0-9._-]/, "_", safe)
                    chunkfile = outdir "/" safe ".chunk"
                    print buf > chunkfile
                    close(chunkfile)
                    print path >> (outdir "/_files")
                    buf = ""
                }
            }
            /^diff --git a\/[^ ]+ b\/[^ ]+/ {
                flush()
                sub(/^diff --git a\/[^ ]+ b\//, "")
                path = $0
                buf = "diff --git a/" path " b/" path
                next
            }
            /^index [0-9a-f]+\.\.[0-9a-f]+/ { next }   # skip blob-SHA noise
            { buf = buf "\n" $0 }
            END { flush() }
        ' "$infile"
    }

    split_patch "$UP_PATCH_B"                             "$SPLIT_BASELINE"
    split_patch "$UP_PATCH_T"                             "$SPLIT_TARGET"
    split_patch "$REF_DIR/$REFERENCE_KERNEL_PATCH"        "$SPLIT_REF"

    n_base=$(wc -l < "$SPLIT_BASELINE/_files" 2>/dev/null | tr -d ' ' || echo 0)
    n_tgt=$(wc -l  < "$SPLIT_TARGET/_files"   2>/dev/null | tr -d ' ' || echo 0)
    n_ref=$(wc -l  < "$SPLIT_REF/_files"      2>/dev/null | tr -d ' ' || echo 0)
    dim "   files per patch:  baseline=$n_base  target=$n_tgt  reference=$n_ref"

    # ── Step 4: Identify drifted files (chunk differs between base and target)
    info ""
    info "Step 4/5: Identifying files whose upstream coverage changed…"

    DRIFTED_LIST="$OUT/reports/drifted-files.txt"
    : > "$DRIFTED_LIST"

    # Shell-side path→safe converter. Uses `printf` (no trailing newline) to
    # match awk's gsub behaviour — otherwise `tr -c` would translate the
    # newline appended by `echo` into '_' and produce Makefile_.chunk instead
    # of Makefile.chunk, causing every file to mismatch.
    sanitise() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

    # union of baseline + target file lists
    cat "$SPLIT_BASELINE/_files" "$SPLIT_TARGET/_files" 2>/dev/null \
        | sort -u \
        | while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        safe=$(sanitise "$path")
        cb="$SPLIT_BASELINE/$safe.chunk"
        ct="$SPLIT_TARGET/$safe.chunk"
        # If one side is missing, it's drift
        if [[ ! -f "$cb" || ! -f "$ct" ]] || ! cmp -s "$cb" "$ct"; then
            echo "$path"
        fi
    done > "$DRIFTED_LIST"

    DRIFTED_COUNT=$(wc -l < "$DRIFTED_LIST" | tr -d ' ')
    ok "drifted files: $DRIFTED_COUNT"

    # Build reconciliation bundles for each drifted file
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        safe=$(sanitise "$path")
        bundle="$OUT/reconciliation/$safe"
        mkdir -p "$bundle"
        echo "$path" > "$bundle/PATH"

        [[ -f "$SPLIT_BASELINE/$safe.chunk" ]] && cp "$SPLIT_BASELINE/$safe.chunk" "$bundle/upstream-baseline.chunk"
        [[ -f "$SPLIT_TARGET/$safe.chunk"   ]] && cp "$SPLIT_TARGET/$safe.chunk"   "$bundle/upstream-target.chunk"
        [[ -f "$SPLIT_REF/$safe.chunk"      ]] && cp "$SPLIT_REF/$safe.chunk"      "$bundle/reference.chunk"

        # What actually changed upstream for this file
        if [[ -f "$bundle/upstream-baseline.chunk" && -f "$bundle/upstream-target.chunk" ]]; then
            diff -u "$bundle/upstream-baseline.chunk" "$bundle/upstream-target.chunk" \
                > "$bundle/upstream.diff" || true
        elif [[ -f "$bundle/upstream-target.chunk" ]]; then
            echo "# File added upstream between baseline and target" > "$bundle/upstream.diff"
            cat "$bundle/upstream-target.chunk" >> "$bundle/upstream.diff"
        elif [[ -f "$bundle/upstream-baseline.chunk" ]]; then
            echo "# File removed upstream between baseline and target" > "$bundle/upstream.diff"
            cat "$bundle/upstream-baseline.chunk" >> "$bundle/upstream.diff"
        fi

        # Reference status
        ref_status="covered"
        [[ ! -f "$bundle/reference.chunk" ]] && ref_status="NOT covered (needs new hunk)"
        echo "$ref_status" > "$bundle/REFERENCE_STATUS"
    done < "$DRIFTED_LIST"

    # Copy reference patch through unchanged — still authoritative.
    cp "$REF_DIR/$REFERENCE_KERNEL_PATCH"   "$OUT/patches/kernel/003-ask-kernel-hooks.patch"
    cp -r "$REF_DIR/$REFERENCE_SDK_SOURCES" "$OUT/patches/kernel/sdk-sources"
    cp "$REF_DIR/config/ask.config"         "$OUT/"

    if (( DRIFTED_COUNT > 0 )); then
        STATUS="needs_review"
    else
        STATUS="ok"
    fi
fi

# ── Step 5: Manifest + human summary ────────────────────────────────────
info ""
info "Step 5/5: Writing manifest and reconciliation summary…"

SDK_COUNT=$(find "$OUT/patches/kernel/sdk-sources" -type f | wc -l | tr -d ' ')

cat > "$OUT/manifest.json" <<EOF
{
  "generated_at":       "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status":             "$STATUS",
  "reference_repo":     "$REFERENCE_REPO",
  "reference_sha":      "$REF_SHA",
  "upstream_repo":      "$UPSTREAM_REPO",
  "upstream_branch":    "$UPSTREAM_BRANCH",
  "upstream_baseline":  "$BASELINE_SHA",
  "upstream_target":    "$TARGET_SHA",
  "delta_lines":        $DELTA_LINES,
  "drifted_files":      ${DRIFTED_COUNT:-0},
  "sdk_source_count":   $SDK_COUNT,
  "output_dir":         "$OUT"
}
EOF

SUMMARY="$OUT/SUMMARY.md"
{
    echo "# Derivation summary"
    echo
    echo "- **Status:** $STATUS"
    echo "- **Reference:** $REF_SHA (${REFERENCE_REF})"
    echo "- **Upstream baseline:** ${BASELINE_SHA:0:12}"
    echo "- **Upstream target:** ${TARGET_SHA:0:12}"
    echo "- **Upstream delta:** $DELTA_LINES lines"
    echo "- **Drifted files:** ${DRIFTED_COUNT:-0}"
    echo
    if [[ "$STATUS" == "ok" ]]; then
        echo "✅ Reference translation is current. work/derived/patches/kernel is"
        echo "   ready to feed into the kernel build."
    else
        echo "⚠ Upstream changed in ${DRIFTED_COUNT} source file(s) between baseline"
        echo "  and target. Review per-file reconciliation bundles under:"
        echo
        echo "      work/derived/reconciliation/"
        echo
        echo "  Each bundle contains:"
        echo "    PATH                     - original source path"
        echo "    upstream-baseline.chunk  - how upstream patched this file at baseline"
        echo "    upstream-target.chunk    - how upstream patches it at target"
        echo "    upstream.diff            - delta between them (what changed upstream)"
        echo "    reference.chunk          - how reference 6.6 patches it (or absent)"
        echo "    REFERENCE_STATUS         - 'covered' or 'NOT covered (needs new hunk)'"
        echo
        echo "  Steps:"
        echo "    1. For each bundle, decide whether the upstream change also applies to 6.6."
        echo "    2. Update reference.chunk hand to incorporate upstream's change."
        echo "    3. Fold updated chunks back into the reference repo's 003-ask-kernel-hooks.patch."
        echo "    4. Push the update to ${REFERENCE_REPO} and bump REFERENCE_REF."
        echo "    5. Bump UPSTREAM_BASELINE in versions.lock to ${TARGET_SHA:0:12}."
        echo "    6. Re-run ./scripts/derive-patches.sh — should go green (status: ok)."
        echo
        echo "## Drifted files"
        echo
        if [[ -f "$OUT/reports/drifted-files.txt" ]]; then
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                safe=$(printf '%s' "$p" | tr -c 'A-Za-z0-9._-' '_')
                rs=$(cat "$OUT/reconciliation/$safe/REFERENCE_STATUS" 2>/dev/null || echo "?")
                echo "- \`$p\`  —  reference: $rs"
            done < "$OUT/reports/drifted-files.txt"
        fi
    fi
} > "$SUMMARY"

echo
cat "$OUT/manifest.json"
echo
ok "derived artifacts ready in: $OUT"
info "summary:  $SUMMARY"
[[ "$STATUS" == "needs_review" ]] && warn "reconciliation required — see $OUT/reconciliation/"
exit 0