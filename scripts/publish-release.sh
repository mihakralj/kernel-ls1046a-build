#!/usr/bin/env bash
# publish-release.sh — promote the freshly-derived patch set from work/derived/
# into the committed, last-known-good release/ directory at the repo root.
#
# This is the ONLY supported way to update release/. The committed tree is the
# authoritative build input for consumers who do not want to run the full
# derivation pipeline (kernel-build CI, air-gapped builds, PR reviewers).
#
# Safety:
#   - Refuses to run unless work/derived/manifest.json::status == "ok".
#   - Refuses to run if work/derived/reconciliation/ has any entries.
#   - Only authoritative artefacts are copied (patches, config, manifest).
#     SUMMARY.md, reports/, and reconciliation/ are NEVER published.
#
# Usage:
#   ./scripts/publish-release.sh              # promote work/derived/ → release/
#   ./scripts/publish-release.sh --force      # promote even if manifest.status != "ok"
#   ./scripts/publish-release.sh --check      # verify release/ matches work/derived/
#
# Exit codes:
#   0  published successfully, or --check says release/ is in sync
#   1  precondition failed (status != ok, missing work/derived, etc.)
#   2  --check: release/ differs from work/derived/ (stale committed tree)

set -euo pipefail
source "$(dirname "$0")/common.sh"

need cp find diff jq

FORCE=0
CHECK_ONLY=0
while (( $# )); do
    case "$1" in
        --force) FORCE=1;      shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
        *) err "unknown arg: $1" ;;
    esac
done

SRC="$WORK_DIR/derived"
DST="$REPO_ROOT/release"

# ── Preconditions ───────────────────────────────────────────────────────
# err() exits with 1 — that is the intended precondition-failure code
# regardless of whether we were invoked in --check mode or not.
[[ -d "$SRC" ]] || err "work/derived/ not found — run ./scripts/derive-patches.sh first"
[[ -f "$SRC/manifest.json" ]] || err "work/derived/manifest.json missing"

STATUS=$(jq -r '.status' "$SRC/manifest.json" 2>/dev/null || echo "?")
RECON_COUNT=0
if [[ -d "$SRC/reconciliation" ]]; then
    RECON_COUNT=$(find "$SRC/reconciliation" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
fi

if (( ! FORCE && ! CHECK_ONLY )); then
    if [[ "$STATUS" != "ok" ]]; then
        err "refusing to publish: manifest.status=\"$STATUS\" (use --force to override)"
    fi
    if (( RECON_COUNT > 0 )); then
        err "refusing to publish: $RECON_COUNT reconciliation bundle(s) pending"
    fi
fi

# ── Stage the authoritative subset ──────────────────────────────────────
# We publish ONLY:
#   - patches/kernel/003-ask-kernel-hooks.patch
#   - patches/kernel/sdk-sources/
#   - ask.config
#   - manifest.json
# We do NOT publish: SUMMARY.md, reports/, reconciliation/
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/patches/kernel"
cp -r "$SRC/patches/kernel/." "$STAGE/patches/kernel/"
cp    "$SRC/ask.config"       "$STAGE/"
cp    "$SRC/manifest.json"    "$STAGE/"

# ── Check mode: diff staged vs committed, no writes ─────────────────────
if (( CHECK_ONLY )); then
    if [[ ! -d "$DST" ]]; then
        warn "release/ does not exist yet"
        exit 2
    fi
    # Ignore README.md (maintained only in release/, never staged) and
    # manifest.json (carries a per-run timestamp; compare the provenance
    # fields separately for a semantic check).
    if diff -qr --exclude=README.md --exclude=manifest.json \
            "$STAGE" "$DST" >/dev/null 2>&1; then
        # Semantic manifest check: compare only the provenance fields that
        # actually identify the derivation (SHAs + counts), not timestamp.
        if [[ -f "$STAGE/manifest.json" && -f "$DST/manifest.json" ]]; then
            _fields='{ref: .reference_sha, ubase: .upstream_baseline, utarg: .upstream_target, status: .status, drift: .drifted_files, sdk: .sdk_source_count}'
            _s=$(jq -cS "$_fields" "$STAGE/manifest.json")
            _d=$(jq -cS "$_fields" "$DST/manifest.json")
            if [[ "$_s" != "$_d" ]]; then
                warn "release/manifest.json provenance differs:"
                echo "   staged:    $_s"
                echo "   committed: $_d"
                exit 2
            fi
        fi
        ok "release/ is in sync with work/derived/ (provenance matches)"
        exit 0
    else
        warn "release/ differs from work/derived/:"
        diff -qr --exclude=README.md --exclude=manifest.json \
            "$STAGE" "$DST" || true
        exit 2
    fi
fi

# ── Publish: replace release/ atomically ────────────────────────────────
info "publishing work/derived/ → release/"
[[ "$STATUS" == "ok" ]] \
    && dim "   manifest.status = ok" \
    || warn "   manifest.status = $STATUS (published with --force)"
dim "   reference_sha     = $(jq -r '.reference_sha'    "$SRC/manifest.json")"
dim "   upstream_baseline = $(jq -r '.upstream_baseline' "$SRC/manifest.json")"
dim "   upstream_target   = $(jq -r '.upstream_target'   "$SRC/manifest.json")"
dim "   sdk_source_count  = $(jq -r '.sdk_source_count'  "$SRC/manifest.json")"

# Remove only the directories/files we manage — never touch unrelated files
# that a maintainer might have added under release/.
rm -rf "$DST/patches" "$DST/ask.config" "$DST/manifest.json"
mkdir -p "$DST"
cp -r "$STAGE/." "$DST/"

# README (only (re)written if absent or clearly ours) ────────────────────
README="$DST/README.md"
if [[ ! -f "$README" ]] || grep -q 'managed by scripts/publish-release.sh' "$README" 2>/dev/null; then
    cat > "$README" <<'EOF'
# release/ — committed last-known-good ASK 6.6 artefacts

This directory is **managed by scripts/publish-release.sh**. Do not edit by hand.

## Contents

| Path | Purpose |
|---|---|
| `patches/kernel/003-ask-kernel-hooks.patch` | monolithic kernel patch (feeds build) |
| `patches/kernel/sdk-sources/` | SDK source files to drop into the kernel tree |
| `ask.config` | kernel config fragment |
| `manifest.json` | provenance: which reference/upstream SHAs produced these artefacts |

## How to update

```bash
./scripts/run-pipeline.sh --publish    # runs the full pipeline and promotes
# or, manually after inspecting work/derived/:
./scripts/publish-release.sh
```

`publish-release.sh` refuses to run unless `work/derived/manifest.json::status == "ok"`
(i.e. no reconciliation bundles pending). Use `--force` only if you know what
you're doing.

## How consumers use it

`patch-health.sh` and any downstream kernel build prefer, in order:
1. `work/derived/` (freshly derived, when present)
2. `release/`      (committed last-known-good — this directory)
3. `work/reference/patches/kernel/` (raw upstream reference, final fallback)

So when all three fetchers report "unchanged" and this directory is present,
no network or derivation work is needed — `release/` already holds the answer.
EOF
    ok "wrote $README"
fi

ok "published to: $DST"
echo
find "$DST" -maxdepth 3 -type f | sort | sed 's|^|   |'