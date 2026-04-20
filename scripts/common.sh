#!/usr/bin/env bash
# common.sh — shared helpers, sourced by all other scripts
#
# Not executable on its own. Source it like:
#   source "$(dirname "$0")/common.sh"

# Resolve repo root regardless of caller CWD
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    export REPO_ROOT
fi

export WORK_DIR="${REPO_ROOT}/work"
export SCRIPTS_DIR="${REPO_ROOT}/scripts"

# Colour-aware logging (no colour when not a TTY)
if [[ -t 1 ]]; then
    _C_BLUE=$'\033[1;34m'; _C_YEL=$'\033[1;33m'; _C_RED=$'\033[1;31m'
    _C_GRN=$'\033[1;32m'; _C_DIM=$'\033[2m';    _C_RST=$'\033[0m'
else
    _C_BLUE=''; _C_YEL=''; _C_RED=''; _C_GRN=''; _C_DIM=''; _C_RST=''
fi

info()  { printf '%s==>%s %s\n'      "$_C_BLUE" "$_C_RST" "$*"; }
ok()    { printf '%s ✓%s %s\n'       "$_C_GRN"  "$_C_RST" "$*"; }
warn()  { printf '%s⚠ %s%s\n'        "$_C_YEL"  "$*"      "$_C_RST"; }
err()   { printf '%s✗ %s%s\n'        "$_C_RED"  "$*"      "$_C_RST" >&2; exit 1; }
dim()   { printf '%s%s%s\n'          "$_C_DIM"  "$*"      "$_C_RST"; }

# Fetch latest 6.6.y stable version from kernel.org releases.json
# Prints e.g. "6.6.123" to stdout
latest_6_6_y() {
    curl -fsSL https://www.kernel.org/releases.json \
        | jq -r '.releases[] | select(.moniker=="longterm") | select(.version|startswith("6.6.")) | .version' \
        | head -1
}

# Cross-platform nproc
nproc_any() { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# Require command(s) on PATH; exit cleanly if missing
need() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if (( ${#missing[@]} )); then
        err "missing required command(s): ${missing[*]}"
    fi
}

mkdir -p "$WORK_DIR"