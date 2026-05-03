#!/usr/bin/env bash
# publish-binaries.sh — upload compiled kernel .deb artefacts from work/build/
# to a GitHub Release so downstream consumers (e.g. vyos-ls1046-build) can
# pin a stable tag instead of rebuilding.
#
# Prerequisites:
#   - `gh` CLI authenticated (`gh auth status`) with write access to the repo
#   - work/build/*.deb populated by ./scripts/build-kernel.sh
#   - release/manifest.json present (binary provenance)
#
# Tag scheme:  kernel-<kver>-ask<N>
#   kver = kernel version (6.6.123)
#   N    = 1-based revision within kver; bumped on every re-publish of same kver
#   Example: kernel-6.6.123-ask1, kernel-6.6.123-ask2, kernel-6.6.124-ask1
#
# Usage:
#   ./scripts/publish-binaries.sh                     # auto-tag and publish
#   ./scripts/publish-binaries.sh --tag kernel-6.6.123-ask1
#   ./scripts/publish-binaries.sh --draft             # create as draft
#   ./scripts/publish-binaries.sh --dry-run           # print plan, do nothing
#   ./scripts/publish-binaries.sh --force             # overwrite existing tag
#
# Exit codes:
#   0  release created (or draft staged); or --dry-run printed OK
#   1  missing prereqs (no .debs, gh not authed, manifest missing, etc.)
#   2  tag already exists and --force not given

set -euo pipefail
source "$(dirname "$0")/common.sh"

need gh jq sha256sum find

TAG=""
DRAFT=0
DRY_RUN=0
FORCE=0

while (( $# )); do
    case "$1" in
        --tag)      TAG="${2:?--tag needs arg}"; shift 2 ;;
        --draft)    DRAFT=1;   shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --force)    FORCE=1;   shift ;;
        -h|--help)  sed -n '1,28p' "$0"; exit 0 ;;
        *) err "unknown arg: $1" ;;
    esac
done

BUILD_DIR="$WORK_DIR/build"
MANIFEST="$REPO_ROOT/release/manifest.json"

# ── Preconditions ───────────────────────────────────────────────────────
[[ -d "$BUILD_DIR" ]] || err "$BUILD_DIR not found — run ./scripts/build-kernel.sh first"
shopt -s nullglob
DEBS=( "$BUILD_DIR"/*.deb )
shopt -u nullglob
(( ${#DEBS[@]} > 0 )) || err "no .deb files in $BUILD_DIR"
[[ -f "$MANIFEST" ]]   || err "release/manifest.json missing (need provenance)"

gh auth status >/dev/null 2>&1 || err "gh CLI not authenticated; run 'gh auth login'"

# Resolve the repo slug gh should target. Prefer the git 'origin' remote.
REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$REPO_SLUG" ]] || err "cannot resolve GitHub repo slug (cd into a cloned repo)"

# ── Kernel version detection ────────────────────────────────────────────
# Pull kver from a linux-image-*/linux-headers-* .deb filename (ignore userspace
# .debs like iptables_1.8.10+ask1_... whose upstream version looks like a kver),
# falling back to work/.kernel-version.
KVER=""
for d in "${DEBS[@]}"; do
    n="$(basename "$d")"
    # e.g. linux-image-6.6.137-ask_6.6.137-1_arm64.deb
    #      linux-headers-6.6.137-ask_6.6.137-1_arm64.deb
    if [[ "$n" =~ ^linux-(image|headers)-([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        KVER="${BASH_REMATCH[2]}"
        break
    fi
done
[[ -z "$KVER" && -f "$WORK_DIR/.kernel-version" ]] && KVER=$(cat "$WORK_DIR/.kernel-version")
[[ -n "$KVER" ]] || err "cannot determine kernel version from linux-image/linux-headers .deb names or work/.kernel-version"

# ── Auto-compute tag (next -askN for this kver) ─────────────────────────
if [[ -z "$TAG" ]]; then
    existing=$(gh release list -R "$REPO_SLUG" -L 200 --json tagName -q '.[].tagName' 2>/dev/null || true)
    N=1
    while grep -qx "kernel-${KVER}-ask${N}" <<< "$existing"; do
        N=$((N+1))
    done
    TAG="kernel-${KVER}-ask${N}"
fi

# ── Tag existence guard ─────────────────────────────────────────────────
if gh release view -R "$REPO_SLUG" "$TAG" >/dev/null 2>&1; then
    if (( FORCE )); then
        warn "--force: will overwrite existing release '$TAG'"
    else
        err "release '$TAG' already exists (use --force to overwrite, or --tag to pick another)"
    fi
fi

# ── Stage release assets ────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Copy the .debs + buildinfo/changes if present
for f in "${DEBS[@]}"; do cp "$f" "$STAGE/"; done
shopt -s nullglob
for f in "$BUILD_DIR"/*.changes "$BUILD_DIR"/*.buildinfo; do
    cp "$f" "$STAGE/"
done
shopt -u nullglob

# ── Enrich manifest with release-time provenance ────────────────────────
# Start from the derive-patches manifest, drop host-specific path, then add:
#   - kernel_version           (explicit field)
#   - upstream_{target,baseline}_{committer_date,author_date,subject}
#   - reference_{committer_date,author_date,subject}
#   - published_at             (release timestamp)
#   - debian_sources[]         ({package, version, architecture, filename, sha256})
#
# All lookups are best-effort: if a git dir or field is missing we emit null
# rather than failing the release.

_git_show() {
    # $1 = gitdir, $2 = sha, $3 = format (e.g. %cI, %aI, %s)
    local gd="$1" sha="$2" fmt="$3"
    [[ -d "$gd" && -n "$sha" && "$sha" != "unknown" ]] || { echo ""; return; }
    git --git-dir="$gd" show -s --format="$fmt" "$sha" 2>/dev/null || echo ""
}

REF_SHA=$(jq -r '.reference_sha // "unknown"'      "$MANIFEST")
UP_TARGET=$(jq -r '.upstream_target // "unknown"'  "$MANIFEST")
UP_BASE=$(jq -r  '.upstream_baseline // "unknown"' "$MANIFEST")
SDK_COUNT=$(jq -r '.sdk_source_count // 0'         "$MANIFEST")

UP_GITDIR="$WORK_DIR/upstream.git"
REF_GITDIR="$WORK_DIR/reference/.git"

UP_TARGET_CDATE=$(_git_show "$UP_GITDIR" "$UP_TARGET" %cI)
UP_TARGET_ADATE=$(_git_show "$UP_GITDIR" "$UP_TARGET" %aI)
UP_TARGET_SUBJ=$( _git_show "$UP_GITDIR" "$UP_TARGET" %s)
UP_BASE_CDATE=$(  _git_show "$UP_GITDIR" "$UP_BASE"   %cI)
UP_BASE_SUBJ=$(   _git_show "$UP_GITDIR" "$UP_BASE"   %s)
REF_CDATE=$(      _git_show "$REF_GITDIR" "$REF_SHA"  %cI)
REF_ADATE=$(      _git_show "$REF_GITDIR" "$REF_SHA"  %aI)
REF_SUBJ=$(       _git_show "$REF_GITDIR" "$REF_SHA"  %s)

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build debian_sources[] JSON array from every non-kernel .deb
DEB_SOURCES_JSON="[]"
if command -v dpkg-deb >/dev/null 2>&1; then
    DEB_SOURCES_JSON="$(
        for f in "${DEBS[@]}"; do
            bn="$(basename "$f")"
            # skip kernel .debs — they have their own kernel_version field
            [[ "$bn" == linux-* ]] && continue
            pkg=$(dpkg-deb -f "$f" Package 2>/dev/null || echo "")
            ver=$(dpkg-deb -f "$f" Version 2>/dev/null || echo "")
            arch=$(dpkg-deb -f "$f" Architecture 2>/dev/null || echo "")
            sha=$(sha256sum "$f" | awk '{print $1}')
            jq -n --arg p "$pkg" --arg v "$ver" --arg a "$arch" \
                  --arg fn "$bn" --arg s "$sha" \
                '{package:$p, version:$v, architecture:$a, filename:$fn, sha256:$s}'
        done | jq -s '.'
    )"
fi

# Attach enriched manifest.json — drop work-host-specific field, then augment
jq --arg kver        "$KVER" \
   --arg pub_at      "$PUBLISHED_AT" \
   --arg up_t_cdate  "$UP_TARGET_CDATE" \
   --arg up_t_adate  "$UP_TARGET_ADATE" \
   --arg up_t_subj   "$UP_TARGET_SUBJ" \
   --arg up_b_cdate  "$UP_BASE_CDATE" \
   --arg up_b_subj   "$UP_BASE_SUBJ" \
   --arg ref_cdate   "$REF_CDATE" \
   --arg ref_adate   "$REF_ADATE" \
   --arg ref_subj    "$REF_SUBJ" \
   --argjson debs    "$DEB_SOURCES_JSON" \
   '
    del(.output_dir) +
    {
        kernel_version:                $kver,
        published_at:                  $pub_at,
        upstream_target_committer_date: ($up_t_cdate | select(. != "") // null),
        upstream_target_author_date:    ($up_t_adate | select(. != "") // null),
        upstream_target_subject:        ($up_t_subj  | select(. != "") // null),
        upstream_baseline_committer_date:($up_b_cdate| select(. != "") // null),
        upstream_baseline_subject:      ($up_b_subj  | select(. != "") // null),
        reference_committer_date:       ($ref_cdate  | select(. != "") // null),
        reference_author_date:          ($ref_adate  | select(. != "") // null),
        reference_subject:              ($ref_subj   | select(. != "") // null),
        debian_sources:                 $debs
    }
   ' "$MANIFEST" > "$STAGE/manifest.json"

# Generate SHA256SUMS across all assets (except itself)
( cd "$STAGE" && sha256sum -- * > SHA256SUMS ) || err "sha256sum generation failed"

# ── Release notes ───────────────────────────────────────────────────────
NOTES="$STAGE/.release-notes.md"
{
    echo "# ASK kernel $KVER"
    echo
    echo "Natively built linux-$KVER for arm64 (NXP LS1046A) with the ASK fast-path patch set."
    echo
    echo "## Provenance"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Kernel version      | \`$KVER\` |"
    echo "| Published (UTC)     | \`$PUBLISHED_AT\` |"
    echo "| SDK source files    | $SDK_COUNT |"
    echo
    echo "### Upstream repositories"
    echo
    echo "| Repo | SHA | Committed | Subject |"
    echo "|---|---|---|---|"
    printf '| reference (\`ask-ls1046a-6.6\`) | `%s` | %s | %s |\n' \
        "${REF_SHA:0:12}" "${REF_CDATE:-n/a}" "${REF_SUBJ:-n/a}"
    printf '| upstream target (\`ASK\` mt-6.12.y) | `%s` | %s | %s |\n' \
        "${UP_TARGET:0:12}" "${UP_TARGET_CDATE:-n/a}" "${UP_TARGET_SUBJ:-n/a}"
    if [[ -n "$UP_BASE" && "$UP_BASE" != "unknown" && "$UP_BASE" != "$UP_TARGET" ]]; then
        printf '| upstream baseline | `%s` | %s | %s |\n' \
            "${UP_BASE:0:12}" "${UP_BASE_CDATE:-n/a}" "${UP_BASE_SUBJ:-n/a}"
    fi
    echo
    # Debian userspace sources (non-kernel .debs), if any
    DEB_ROWS=$(jq -r '.[] | "| `\(.package)` | `\(.version)` | `\(.architecture)` |"' <<< "$DEB_SOURCES_JSON")
    if [[ -n "$DEB_ROWS" ]]; then
        echo "### Debian userspace sources rebuilt"
        echo
        echo "| Package | Version | Arch |"
        echo "|---|---|---|"
        echo "$DEB_ROWS"
        echo
    fi
    echo "Full provenance in the attached \`manifest.json\`."
    echo
    echo "## Assets"
    echo
    ( cd "$STAGE" && find . -maxdepth 1 -type f ! -name '.release-notes.md' -printf '- `%P`\n' | sort )
    echo
    echo "## Verify"
    echo
    echo '```bash'
    echo "gh release download -R $REPO_SLUG $TAG"
    echo "sha256sum -c SHA256SUMS"
    echo '```'
    echo
    echo "## Consume (vyos-ls1046-build)"
    echo
    echo '```bash'
    echo "KERNEL_TAG=$TAG"
    echo 'gh release download -R '"$REPO_SLUG"' "$KERNEL_TAG" \\'
    echo '    --pattern "linux-*.deb" --pattern "SHA256SUMS" --pattern "manifest.json" \\'
    echo '    -D /tmp/ask-kernel/'
    echo '(cd /tmp/ask-kernel && sha256sum -c SHA256SUMS)'
    echo '```'
} > "$NOTES"

# ── Dry-run: print plan and exit ────────────────────────────────────────
info "GitHub Release plan"
dim  "   repo:         $REPO_SLUG"
dim  "   tag:          $TAG"
dim  "   title:        ASK kernel $KVER (reference ${REF_SHA:0:12})"
dim  "   draft:        $( ((DRAFT)) && echo yes || echo no )"
dim  "   assets:"
( cd "$STAGE" && find . -maxdepth 1 -type f ! -name '.release-notes.md' -printf '                 %f\n' | sort )

if (( DRY_RUN )); then
    warn "--dry-run: not creating release"
    echo "---- notes ----"
    cat "$NOTES"
    exit 0
fi

# ── Delete existing release if --force ─────────────────────────────────
if (( FORCE )) && gh release view -R "$REPO_SLUG" "$TAG" >/dev/null 2>&1; then
    info "deleting existing release '$TAG' (--force)"
    gh release delete -R "$REPO_SLUG" "$TAG" --yes --cleanup-tag 2>/dev/null || \
        gh release delete -R "$REPO_SLUG" "$TAG" --yes
fi

# ── Create the release ──────────────────────────────────────────────────
args=( -R "$REPO_SLUG" "$TAG"
       --title "ASK kernel $KVER (reference ${REF_SHA:0:12})"
       --notes-file "$NOTES" )
(( DRAFT )) && args+=( --draft )

# Asset files (exclude the notes file)
shopt -s nullglob
ASSETS=()
while IFS= read -r -d '' f; do ASSETS+=( "$f" ); done \
    < <(find "$STAGE" -maxdepth 1 -type f ! -name '.release-notes.md' -print0 | sort -z)
shopt -u nullglob

info "creating release $TAG …"
gh release create "${args[@]}" "${ASSETS[@]}"

ok  "published: https://github.com/$REPO_SLUG/releases/tag/$TAG"