#!/usr/bin/env bash
# Cline post-tool-use hook: patch-hunk-validator
#
# Purpose:
#   Catch the silent hunk-truncation bug class (ask13 → ask14 in this repo)
#   where a `*.patch` under release/patches/**/ has an `@@ -a,b +c,d @@`
#   header whose b/d counts disagree with the actual hunk body. `git apply`
#   accepts these and silently drops trailing `+`/context lines, producing
#   a kernel that compiles but is missing critical objects (e.g.
#   obj-$(CONFIG_FSL_SDK_FMAN) was lost from drivers/net/ethernet/freescale/Makefile).
#
# Contract (Cline post-tool-use hook for write_to_file / replace_in_file):
#   - $CLINE_TOOL_PATH (or first arg) = the file just written.
#   - Exit 0 always (this is a non-blocking validator). Issues are surfaced
#     on stderr so the agent sees them on the next turn.
#
# Standalone usage:
#   .clinehooks/patch-hunk-validator.sh release/patches/ask/010-...patch
#   .clinehooks/patch-hunk-validator.sh           # validates ALL patches
#
# Validation per hunk (`@@ -OldStart,OldCount +NewStart,NewCount @@`):
#   - OldCount == count of body lines starting with ' ' or '-'
#   - NewCount == count of body lines starting with ' ' or '+'
#   - Single-line forms `@@ -a +c @@` imply OldCount=NewCount=1
#
# Notes:
#   - Lines starting with '\' (e.g. "\ No newline at end of file") are skipped.
#   - Validation stops at the next "diff --git" / "--- " / next "@@".
set -uo pipefail

target="${1:-${CLINE_TOOL_PATH:-}}"

# Decide which files to scan.
declare -a files=()
if [[ -n "${target}" ]]; then
    case "${target}" in
        release/patches/*.patch|release/patches/**/*.patch)
            files=("${target}") ;;
        *)
            # Hook fired on a non-patch edit; nothing to do.
            exit 0 ;;
    esac
else
    while IFS= read -r -d '' f; do files+=("${f}"); done \
        < <(find release/patches -type f -name '*.patch' -print0 2>/dev/null || true)
fi

(( ${#files[@]} == 0 )) && exit 0

issues=0
total_hunks=0

validate_one() {
    local file="$1"
    local in_hunk=0
    local exp_old=0 exp_new=0
    local got_old=0 got_new=0
    local hunk_lineno=0
    local hunk_header=""
    local lineno=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$((lineno + 1))

        # Hunk header?
        if [[ "${line}" =~ ^@@\ -([0-9]+)(,([0-9]+))?\ \+([0-9]+)(,([0-9]+))?\ @@ ]]; then
            # Flush previous hunk
            if (( in_hunk )); then
                if (( got_old != exp_old || got_new != exp_new )); then
                    printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
                    printf '     header : %s\n' "${hunk_header}" >&2
                    printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
                    printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
                    issues=$((issues + 1))
                fi
            fi

            in_hunk=1
            total_hunks=$((total_hunks + 1))
            hunk_lineno=${lineno}
            hunk_header="${line}"
            exp_old="${BASH_REMATCH[3]:-1}"
            exp_new="${BASH_REMATCH[6]:-1}"
            got_old=0
            got_new=0
            continue
        fi

        # End of hunk markers?
        if (( in_hunk )); then
            case "${line}" in
                'diff --git '*|'--- '*|'+++ '*|'index '*|'Index: '*)
                    if (( got_old != exp_old || got_new != exp_new )); then
                        printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
                        printf '     header : %s\n' "${hunk_header}" >&2
                        printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
                        printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
                        issues=$((issues + 1))
                    fi
                    in_hunk=0
                    continue
                    ;;
                '\'*) continue ;;       # "\ No newline at end of file"
                '-- ')                   # git format-patch signature delimiter → end of patch body
                    if (( got_old != exp_old || got_new != exp_new )); then
                        printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
                        printf '     header : %s\n' "${hunk_header}" >&2
                        printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
                        printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
                        issues=$((issues + 1))
                    fi
                    in_hunk=0
                    continue
                    ;;
                ' '*) got_old=$((got_old + 1)); got_new=$((got_new + 1)) ;;
                '-'*) got_old=$((got_old + 1)) ;;
                '+'*) got_new=$((got_new + 1)) ;;
                '')   # empty line → end-of-hunk (real diff context lines are at least " ")
                    if (( got_old != exp_old || got_new != exp_new )); then
                        printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
                        printf '     header : %s\n' "${hunk_header}" >&2
                        printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
                        printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
                        issues=$((issues + 1))
                    fi
                    in_hunk=0
                    continue
                    ;;
                *)    # unknown line; treat as end-of-hunk
                    if (( got_old != exp_old || got_new != exp_new )); then
                        printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
                        printf '     header : %s\n' "${hunk_header}" >&2
                        printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
                        printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
                        issues=$((issues + 1))
                    fi
                    in_hunk=0
                    ;;
            esac
        fi
    done < "${file}"

    # Flush trailing hunk at EOF.
    if (( in_hunk )); then
        if (( got_old != exp_old || got_new != exp_new )); then
            printf '  %s:%d: hunk header mismatch\n' "${file}" "${hunk_lineno}" >&2
            printf '     header : %s\n' "${hunk_header}" >&2
            printf '     declared OldCount=%d NewCount=%d\n' "${exp_old}" "${exp_new}" >&2
            printf '     actual   OldCount=%d NewCount=%d\n' "${got_old}" "${got_new}" >&2
            issues=$((issues + 1))
        fi
    fi
}

for f in "${files[@]}"; do
    [[ -f "${f}" ]] || continue
    validate_one "${f}"
done

if (( issues > 0 )); then
    {
        echo
        echo "[hook: patch-hunk-validator] ${issues} hunk header mismatch(es) across ${total_hunks} hunk(s) in ${#files[@]} file(s)."
        echo
        echo "This is the silent-truncation class of bug (ask13 → ask14):"
        echo "  @@ -a,b +c,d @@   →   b must equal context+'-' lines"
        echo "                        d must equal context+'+' lines"
        echo
        echo "git apply will SUCCEED on a wrong header but truncate added lines."
        echo "Re-run after fixing:"
        echo "  rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/"
        echo "  bash scripts/patch-health.sh --source release"
        echo "  patch -p1 -d work/linux-6.6.135 < <bad.patch>"
        echo "  grep -n '<expected post-patch content>' work/linux-6.6.135/<file>"
        echo
        echo "See .clinerules/10-patch-authoring.md."
    } >&2
fi

# Non-blocking validator.
exit 0