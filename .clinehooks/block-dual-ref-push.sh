#!/usr/bin/env bash
# Cline pre-tool-use hook: block-dual-ref-push
#
# Purpose:
#   Hard-block any `git push` whose argv lists BOTH a protected branch
#   ref (lts-6.6-ls1046a, main) AND a kernel-* tag in the same invocation.
#   The CI workflow triggers on both refs separately; pushing both at
#   once wastes ~22 minutes of GitHub Actions ARM64 minutes per occurrence.
#
# Contract (Cline pre-tool-use hook for execute_command):
#   - Receives the proposed command on stdin or as $CLINE_COMMAND.
#   - Exit 0  → allow command.
#   - Exit !=0 → block command; stderr is shown to the user/agent.
#
# Also detects:
#   - `git push --follow-tags` while a kernel-* tag exists on HEAD/branch.
#   - `git push --tags <branch>` (pushes all tags + a branch).
#
# Install (repo-local):
#   chmod +x .clinehooks/block-dual-ref-push.sh
#   Wire it via your Cline hook config (e.g. .cline/hooks.json) as a
#   pre-tool-use hook on the execute_command tool.
#
# Standalone smoke test:
#   echo 'git push origin lts-6.6-ls1046a kernel-6.6.137-ask15' \
#     | .clinehooks/block-dual-ref-push.sh   # → exit 1, message
#   echo 'git push origin kernel-6.6.137-ask15' \
#     | .clinehooks/block-dual-ref-push.sh   # → exit 0
set -euo pipefail

CMD="${CLINE_COMMAND:-}"
if [[ -z "${CMD}" ]] && [[ ! -t 0 ]]; then
    CMD="$(cat || true)"
fi

# Fast path: not a git push → allow.
if ! grep -qE '(^|[[:space:];&|])git[[:space:]]+push([[:space:]]|$)' <<<"${CMD}"; then
    exit 0
fi

PROTECTED_BRANCH_RE='(^|[[:space:]])(lts-6\.6-ls1046a|main)([[:space:]]|$)'
KERNEL_TAG_RE='(^|[[:space:]])kernel-[0-9][0-9A-Za-z._-]*([[:space:]]|$)'

has_branch=0
has_tag=0

grep -qE "${PROTECTED_BRANCH_RE}" <<<"${CMD}" && has_branch=1 || true
grep -qE "${KERNEL_TAG_RE}"        <<<"${CMD}" && has_tag=1    || true

# Detect dangerous flag combos that implicitly push both.
follow_tags=0
push_all_tags=0
grep -qE '(^|[[:space:]])--follow-tags([[:space:]]|$)' <<<"${CMD}" && follow_tags=1 || true
grep -qE '(^|[[:space:]])--tags([[:space:]]|$)'        <<<"${CMD}" && push_all_tags=1 || true

block=0
reason=""

if (( has_branch && has_tag )); then
    block=1
    reason="Command pushes a protected branch ref AND a kernel-* tag in one git push."
elif (( follow_tags )) && (( has_branch )); then
    block=1
    reason="Command uses --follow-tags with a branch ref; this implicitly pushes any kernel-* tag on HEAD."
elif (( push_all_tags )) && (( has_branch )); then
    block=1
    reason="Command uses --tags with a branch ref; this pushes ALL tags including kernel-*."
fi

if (( block )); then
    cat >&2 <<EOF
[hook: block-dual-ref-push] BLOCKED

  Command: ${CMD}
  Reason : ${reason}

The CI workflow .github/workflows/build-and-release.yml fires twice
when a branch and a kernel-* tag are pushed together — once for the
branch (safety-net build, no release) and once for the tag (release
build). The concurrency: group does NOT deduplicate them because they
are distinct ref kinds. Each redundant ARM64 build wastes ~22 minutes.

See .clinerules/00-tag-discipline.md.

Allowed alternatives:
  # Tag-only release push:
  git push origin kernel-6.6.137-askN

  # Branch sanity-check (before cutting any tag):
  git push origin lts-6.6-ls1046a

If you really intend both pushes, do them as TWO separate invocations
in the correct order:
  1) git push origin lts-6.6-ls1046a       # land branch first
  2) git push origin kernel-6.6.137-askN   # then cut/push tag
EOF
    exit 1
fi

exit 0