#!/usr/bin/env bash
# run-pipeline.sh — orchestrate the full ASK 6.6 derivation pipeline in the
# correct order. This is the one entry point most users should call.
#
# Pipeline:
#   1. fetch-kernel.sh       (linux-6.6.y stable tarball)        \
#   2. fetch-reference.sh    (static 6.6 translation repo)        | independent
#   3. fetch-upstream.sh     (active 6.12 ASK upstream mirror)    /
#   4. sync-upstream.sh      (CI gate: classify new commits)
#   5. derive-patches.sh     (re-derive 6.6 patches if needed)
#   6. patch-health.sh       (verify patches apply to kernel tree)
#
#   split-reference-patch.sh is intentionally NOT in the pipeline — it is an
#   out-of-band maintenance utility for grooming the reference repo.
#
# Usage:
#   ./scripts/run-pipeline.sh                 # full pipeline
#   ./scripts/run-pipeline.sh 6.6.123         # pin kernel version
#   ./scripts/run-pipeline.sh --skip-fetch    # reuse existing work/ caches
#   ./scripts/run-pipeline.sh --no-derive     # fetch + sync + health only
#   ./scripts/run-pipeline.sh --no-health     # skip final patch-apply probe
#   ./scripts/run-pipeline.sh --publish       # on status=ok, promote work/derived/
#                                             # into the committed release/ tree
#   ./scripts/run-pipeline.sh --build         # apply-to-tree + build-kernel (.deb)
#   ./scripts/run-pipeline.sh --ask-extras    # + build-ask-modules (OOT cdx/fci/auto_bridge)
#                                             #   (implies --build; requires kernel build first)
#   ./scripts/run-pipeline.sh --release-binaries # upload work/build/*.deb to GitHub Releases
#   ./scripts/run-pipeline.sh --dry-run       # print steps, do not execute
#
# Exit codes:
#   0  pipeline completed successfully
#   1  patch-health failed (patches do not apply)
#   2  sync-upstream reported T2 commits AND --no-derive was given
#      (i.e. the operator was told to do work but pipeline didn't do it)
#   3  derive-patches produced status=needs_review (manual reconciliation)
#   4  --build: apply-to-tree or build-kernel failed
#   5  --release-binaries: publish-binaries failed
#   >0 any prerequisite step failed

set -euo pipefail
source "$(dirname "$0")/common.sh"

# ── Argument parsing ────────────────────────────────────────────────────
KERNEL_VERSION_ARG=""
SKIP_FETCH=0
DO_DERIVE=1
DO_HEALTH=1
DO_PUBLISH=0
DO_BUILD=0
DO_ASK_EXTRAS=0
DO_RELEASE_BIN=0
DRY_RUN=0

while (( $# )); do
    case "$1" in
        --skip-fetch)        SKIP_FETCH=1;     shift ;;
        --no-derive)         DO_DERIVE=0;      shift ;;
        --no-health)         DO_HEALTH=0;      shift ;;
        --publish)           DO_PUBLISH=1;     shift ;;
        --build)             DO_BUILD=1;       shift ;;
        --ask-extras)        DO_ASK_EXTRAS=1; DO_BUILD=1; shift ;;
        --release-binaries)  DO_RELEASE_BIN=1; shift ;;
        --dry-run)           DRY_RUN=1;        shift ;;
        -h|--help)           sed -n '1,36p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) err "unknown flag: $1" ;;
        *)  KERNEL_VERSION_ARG="$1"; shift ;;
    esac
done

# ── Step runner ─────────────────────────────────────────────────────────
STEP=0
_STEP_START=0
_step_begin() {
    local label="$1"
    STEP=$((STEP+1))
    echo
    begin_group "Step $STEP: $label"
    info "── Step $STEP: $label ──"
    _STEP_START=$(date +%s)
}
_step_end() {
    local elapsed=$(( $(date +%s) - _STEP_START ))
    dim "   (step $STEP done in ${elapsed}s)"
    end_group
}

run_step() {
    local label="$1"; shift
    _step_begin "$label"
    dim "   \$ $*"
    if (( DRY_RUN )); then
        _step_end
        return 0
    fi
    "$@"
    _step_end
}

# Same as run_step but tolerates a specific non-zero exit code (passed via
# ALLOW_EXIT) and stores it in LAST_EXIT for the caller to inspect.
LAST_EXIT=0
run_step_softfail() {
    local allow_exit="$1"; shift
    local label="$1"; shift
    _step_begin "$label"
    dim "   \$ $*"
    if (( DRY_RUN )); then
        LAST_EXIT=0
        _step_end
        return 0
    fi
    set +e
    "$@"
    LAST_EXIT=$?
    set -e
    _step_end
    if (( LAST_EXIT != 0 && LAST_EXIT != allow_exit )); then
        err "step '$label' failed with exit $LAST_EXIT"
    fi
}

# ── Banner ──────────────────────────────────────────────────────────────
echo
ok "ASK lts_6.6_ls1046a — pipeline starting"
[[ -n "$KERNEL_VERSION_ARG" ]] && dim "   pinned kernel: $KERNEL_VERSION_ARG"
(( SKIP_FETCH )) && dim "   --skip-fetch: reusing existing work/ caches"
(( DO_DERIVE  )) || dim "   --no-derive:  derive-patches will be skipped"
(( DO_HEALTH  )) || dim "   --no-health:  patch-health will be skipped"
(( DO_PUBLISH )) && dim "   --publish:    release/ will be refreshed if status=ok"
(( DO_BUILD   )) && dim "   --build:      apply-to-tree + build-kernel will run"
(( DO_ASK_EXTRAS )) && dim "   --ask-extras: + build-ask-modules (cdx/fci/auto_bridge OOT .debs)"
(( DO_RELEASE_BIN )) && dim "   --release-binaries: .debs → GitHub Release"
(( DRY_RUN    )) && warn "DRY-RUN: no commands will actually execute"

# ── 1–3. Fetch (independent; sequential here for clean log output) ──────
if (( SKIP_FETCH )); then
    # Glob doesn't expand inside [[ -d ]]; use a real expansion check.
    shopt -s nullglob
    _kdirs=( "$WORK_DIR"/linux-*/ )
    shopt -u nullglob
    (( ${#_kdirs[@]} > 0 )) \
        || err "--skip-fetch but no work/linux-*/ found; run without --skip-fetch first"
    [[ -d "$WORK_DIR/reference/.git" ]] \
        || err "--skip-fetch but work/reference/ missing; run without --skip-fetch first"
    [[ -d "$WORK_DIR/upstream.git" ]] \
        || err "--skip-fetch but work/upstream.git/ missing; run without --skip-fetch first"
    info "skipping fetchers (--skip-fetch); reusing: ${_kdirs[0]##*/}"
    STEP=3
else
    # Fetchers now exit 0 (unchanged) or 10 (new/changed); both are success.
    # Any other non-zero is a real error. run_step_softfail tolerates the
    # "allow_exit" code and stores the actual exit in LAST_EXIT so we can
    # record per-fetcher change status in the summary.
    KERNEL_CHANGED=0; REF_CHANGED=0; UP_CHANGED=0
    if [[ -n "$KERNEL_VERSION_ARG" ]]; then
        run_step_softfail 10 "fetch kernel ($KERNEL_VERSION_ARG)" \
            "$SCRIPTS_DIR/fetch-kernel.sh" "$KERNEL_VERSION_ARG"
    else
        run_step_softfail 10 "fetch kernel (latest 6.6.y)" \
            "$SCRIPTS_DIR/fetch-kernel.sh"
    fi
    (( LAST_EXIT == 10 )) && KERNEL_CHANGED=1

    run_step_softfail 10 "fetch reference repo" \
        "$SCRIPTS_DIR/fetch-reference.sh"
    (( LAST_EXIT == 10 )) && REF_CHANGED=1

    run_step_softfail 10 "fetch upstream mirror" \
        "$SCRIPTS_DIR/fetch-upstream.sh"
    (( LAST_EXIT == 10 )) && UP_CHANGED=1
fi

# ── 4. Sync (gate) ──────────────────────────────────────────────────────
# Exit 2 from sync-upstream means "T2 commits present, kernel patch work
# needed". That is informational — we proceed to derive-patches in that case.
run_step_softfail 2 "survey upstream (sync-upstream)" \
    "$SCRIPTS_DIR/sync-upstream.sh"
SYNC_EXIT=$LAST_EXIT

if (( SYNC_EXIT == 2 )); then
    warn "upstream has T2 (kernel-patch) commits since baseline"
else
    ok "upstream survey: no T2 work pending"
fi

# ── 5. Derive ───────────────────────────────────────────────────────────
DERIVE_STATUS="skipped"
if (( DO_DERIVE )); then
    run_step "derive 6.6 patches (derive-patches)" \
        "$SCRIPTS_DIR/derive-patches.sh"
    if (( ! DRY_RUN )) && [[ -f "$WORK_DIR/derived/manifest.json" ]]; then
        DERIVE_STATUS=$(grep -o '"status":[[:space:]]*"[^"]*"' \
            "$WORK_DIR/derived/manifest.json" | head -1 \
            | sed 's/.*"\([^"]*\)"$/\1/')
    elif (( DRY_RUN )); then
        DERIVE_STATUS="(dry-run)"
    fi
elif (( SYNC_EXIT == 2 )); then
    warn "T2 commits present but --no-derive was given; manual derive required"
    exit 2
fi

# ── 6. Health ───────────────────────────────────────────────────────────
HEALTH_EXIT=0
if (( DO_HEALTH )); then
    run_step_softfail 1 "verify patches apply (patch-health)" \
        "$SCRIPTS_DIR/patch-health.sh"
    HEALTH_EXIT=$LAST_EXIT
fi

# ── 7. Publish (optional) ───────────────────────────────────────────────
# Only runs on --publish AND when derive-patches produced status=ok AND
# health check passed. Otherwise emits a skip message and does nothing.
PUBLISH_STATUS="skipped"
if (( DO_PUBLISH )); then
    if [[ "$DERIVE_STATUS" != "ok" ]]; then
        warn "--publish: refusing (derive-patches status='$DERIVE_STATUS', must be 'ok')"
        PUBLISH_STATUS="refused (status=$DERIVE_STATUS)"
    elif (( HEALTH_EXIT != 0 )); then
        warn "--publish: refusing (patch-health failed)"
        PUBLISH_STATUS="refused (health failed)"
    else
        run_step "publish work/derived/ → release/ (publish-release)" \
            "$SCRIPTS_DIR/publish-release.sh"
        PUBLISH_STATUS="published"
    fi
fi

# ── 8. Build (optional) ─────────────────────────────────────────────────
# Only runs on --build AND when patch-health passed (we refuse to compile on
# top of known-rejecting patches). apply-to-tree.sh picks its artefact source
# the same way patch-health.sh does: work/derived/ → release/ → reference.
BUILD_STATUS="skipped"
if (( DO_BUILD )); then
    if (( HEALTH_EXIT != 0 )); then
        warn "--build: refusing (patch-health failed)"
        BUILD_STATUS="refused (health failed)"
    elif (( ! DO_HEALTH )); then
        warn "--build: refusing (--no-health given; cannot verify safety)"
        BUILD_STATUS="refused (no-health)"
    else
        run_step_softfail 1 "apply artefacts to kernel tree (apply-to-tree)" \
            "$SCRIPTS_DIR/apply-to-tree.sh"
        APPLY_EXIT=$LAST_EXIT
        if (( APPLY_EXIT != 0 )); then
            BUILD_STATUS="apply-to-tree failed"
        else
            run_step_softfail 1 "cross-compile kernel (build-kernel)" \
                "$SCRIPTS_DIR/build-kernel.sh"
            BUILD_EXIT=$LAST_EXIT
            if (( BUILD_EXIT != 0 )); then
                BUILD_STATUS="build-kernel failed"
            else
                BUILD_STATUS="built (work/build/*.deb)"
            fi
        fi
    fi
fi

# ── 8b. ASK extras: out-of-tree modules, userspace, xtables (optional) ──
# Only runs on --ask-extras AND when the kernel build succeeded. Each sub-
# step is softfail: a failure in one extra does not block the others or the
# kernel .debs. The intent is progressive rollout — we ship what builds and
# flag what doesn't, so a single broken layer doesn't lose the whole release.
ASK_MODULES_STATUS="skipped"
if (( DO_ASK_EXTRAS )); then
    if [[ "$BUILD_STATUS" != "built"* ]]; then
        warn "--ask-extras: refusing (kernel build did not succeed)"
        ASK_MODULES_STATUS="refused (kernel build failed)"
    else
        run_step_softfail 1 "build ASK OOT modules (cdx/fci/auto_bridge)" \
            "$SCRIPTS_DIR/build-ask-modules.sh"
        if (( LAST_EXIT == 0 )); then
            # Disambiguate: the script exits 0 both when a .deb is built and
            # when it intentionally skips (NXP FMan SDK absent). Look for the
            # .deb to tell them apart.
            if compgen -G "$WORK_DIR/build/ask-modules-*.deb" >/dev/null; then
                ASK_MODULES_STATUS="built (ask-modules-*.deb)"
            else
                ASK_MODULES_STATUS="skipped (NXP FMan SDK not layered — see build log)"
            fi
        else
            ASK_MODULES_STATUS="build-ask-modules failed"
        fi
    fi
fi

# ── 9. Release binaries (optional) ──────────────────────────────────────
# Only runs on --release-binaries AND when --build succeeded. Uploads
# work/build/*.deb + SHA256SUMS + manifest.json to a GitHub Release tagged
# kernel-<kver>-ask<N>. Requires gh CLI authenticated.
RELEASE_BIN_STATUS="skipped"
if (( DO_RELEASE_BIN )); then
    if (( ! DO_BUILD )); then
        warn "--release-binaries: refusing (requires --build)"
        RELEASE_BIN_STATUS="refused (no --build)"
    elif [[ "$BUILD_STATUS" != "built"* ]]; then
        warn "--release-binaries: refusing (build did not succeed: $BUILD_STATUS)"
        RELEASE_BIN_STATUS="refused ($BUILD_STATUS)"
    else
        run_step_softfail 1 "upload binaries to GitHub Release (publish-binaries)" \
            "$SCRIPTS_DIR/publish-binaries.sh"
        if (( LAST_EXIT == 0 )); then
            RELEASE_BIN_STATUS="published"
        else
            RELEASE_BIN_STATUS="publish-binaries failed"
        fi
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────
echo
info "── Pipeline summary ──"
if (( SKIP_FETCH )); then
    printf '   kernel:          (cache reused)\n'
    printf '   reference:       (cache reused)\n'
    printf '   upstream:        (cache reused)\n'
else
    printf '   kernel:          %s\n' "$( ((KERNEL_CHANGED)) && echo 'CHANGED'   || echo 'unchanged' )"
    printf '   reference:       %s\n' "$( ((REF_CHANGED))    && echo 'CHANGED'   || echo 'unchanged' )"
    printf '   upstream:        %s\n' "$( ((UP_CHANGED))     && echo 'CHANGED'   || echo 'unchanged' )"
fi
printf '   sync-upstream:   %s\n' "$( ((SYNC_EXIT==0))   && echo 'clean'           || echo 'T2 commits present' )"
printf '   derive-patches:  %s\n' "$DERIVE_STATUS"
if (( DO_HEALTH )); then
    printf '   patch-health:    %s\n' "$( ((HEALTH_EXIT==0)) && echo 'all patches apply' || echo 'REJECTS' )"
else
    printf '   patch-health:    skipped\n'
fi
printf '   publish-release: %s\n' "$PUBLISH_STATUS"
printf '   build-kernel:    %s\n' "$BUILD_STATUS"
printf '   ask-modules:     %s\n' "$ASK_MODULES_STATUS"
printf '   release-bin:     %s\n' "$RELEASE_BIN_STATUS"

# ── Exit code policy ────────────────────────────────────────────────────
if (( HEALTH_EXIT != 0 )); then
    err "patch-health failed — kernel patches do not apply cleanly"
fi
if [[ "$DERIVE_STATUS" == "needs_review" ]]; then
    warn "derive-patches produced reconciliation bundles — see work/derived/reconciliation/"
    exit 3
fi
if (( DO_BUILD )) && [[ "$BUILD_STATUS" != "built"* && "$BUILD_STATUS" != "skipped" ]]; then
    err "--build stage failed: $BUILD_STATUS"
fi
if (( DO_RELEASE_BIN )) && [[ "$RELEASE_BIN_STATUS" == *"failed"* ]]; then
    warn "--release-binaries: $RELEASE_BIN_STATUS"
    exit 5
fi

ok "pipeline complete"
exit 0
