# Rule: Tag Discipline (Producer Release Workflow)

This repo is a **producer**. The CI workflow `.github/workflows/build-and-release.yml` triggers on TWO ref types:

| Trigger | Behavior |
|---|---|
| `push: branches: [lts-6.6-ls1046a, main]` | Safety-net CI build, **no release published** |
| `push: tags: [kernel-*]` | Build **and** publishes a GitHub Release |

A native ARM64 build runs ~22 min. The `concurrency:` group does **not** dedupe branch+tag because they are distinct ref kinds.

## Hard rules

1. **NEVER push a branch ref and a `kernel-*` tag in the same `git push`.**
   - Forbidden: `git push origin lts-6.6-ls1046a kernel-6.6.137-askN`
   - Forbidden: `git push --follow-tags` when HEAD already moved on the branch and a release tag exists.
2. **Release iterations push the TAG ONLY.**
   ```bash
   git commit -am '...'
   git tag kernel-6.6.137-askN
   git push origin kernel-6.6.137-askN     # tag only
   ```
3. **Branch pushes are reserved for non-release commits** (tooling, AGENTS.md, README, scripts). If you need a CI sanity check on those, push the branch in a SEPARATE push, BEFORE cutting the tag.
4. **Never re-use an `askN` tag.** If a release fails, bump to `askN+1`.
5. **Tag name format is fixed**: `kernel-6.6.137-ask<N>` where `<N>` is a positive integer with no leading zeros.

## Pre-tag gate (must pass before `git tag`)

- Clean working tree (`git status` reports nothing).
- Recent green `scripts/patch-health.sh --source release`:
  - `Pass: 21   Fail: 0`
  - `0 SDK conflicts`
  - `265 files to install`
- `release/manifest.json` askN field bumped.
- Defconfig fragments under `release/vyos-base/` unchanged from last green build, unless intentionally modified by this iteration's commits.

Violations of this rule waste ~22 minutes of GitHub Actions ARM64 minutes per occurrence and have happened in production. Treat as P0.