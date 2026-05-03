# Rule: Canonical Tooling Paths

Use the existing scripts under `scripts/` rather than re-implementing their logic inline. They encode invariants and side-effects that are easy to get wrong by hand.

## Canonical scripts

| Script | Purpose |
|---|---|
| `scripts/patch-health.sh --source release` | Validate the patch set. Must report `Pass: 16`, `Fail: 0`, `0 SDK conflicts`, `266 files to install`. |
| `scripts/apply-to-tree.sh` | Apply patches AND copy verbatim SDK source drops into the kernel tree. Owns the 264-file invariant. |
| `scripts/run-pipeline.sh` | Full local build pipeline. Slow; use when verifying end-to-end. |
| `scripts/build-kernel.sh` | Kernel-only build step. |
| `scripts/build-ask-iptables.sh` / `build-ask-modules.sh` / `build-ask-ppp.sh` | Out-of-tree component builds. |
| `scripts/fetch-kernel.sh` | Refresh `work/linux-6.6.137.tar.xz` from upstream. |
| `scripts/fetch-reference.sh` / `fetch-upstream.sh` / `sync-upstream.sh` | Pull upstream / reference trees for diffing. |
| `scripts/derive-patches.sh` | Regenerate patches from a reference tree. |
| `scripts/split-reference-patch.sh` | Split a monolithic reference patch into ASK buckets. |
| `scripts/normalize-patch.awk` | Normalize a `git diff` into the project's canonical patch format. ALWAYS pipe new patches through this. |
| `scripts/diff-vyos-config.sh` | Compare VyOS defconfig fragments vs an upstream reference. |
| `scripts/publish-binaries.sh` / `publish-release.sh` | Release artifact publishing. |
| `scripts/common.sh` | Shared bash helpers — source it; don't duplicate. |

## Hard rules

1. **Do not duplicate script logic** in ad-hoc shell pipelines. Call the script.
2. **Patch generation flow** is fixed:
   ```
   git diff --no-prefix → scripts/normalize-patch.awk → release/patches/<bucket>/NNN-name.patch
   ```
3. **Do not bypass `scripts/apply-to-tree.sh`** when staging the kernel tree. The 264-file SDK install count is enforced through it.
4. **If a script is wrong**, fix it in a `scripts:` commit; don't work around it.
5. **Working directory layout** is fixed:
   - `work/linux-6.6.137.tar.xz` — pristine kernel tarball.
   - `work/linux-6.6.137/` — extracted, dirty working tree (always re-extract before validation).
   - `release/patches/`, `release/vyos-base/`, `release/ask.config`, `release/manifest.json` — sources of truth.

## Useful one-liners

```bash
# Reset to pristine and validate
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
bash scripts/patch-health.sh --source release

# Author a patch
( cd work/linux-6.6.137 && git diff --no-prefix ) \
  | awk -f scripts/normalize-patch.awk \
  > release/patches/ask/0X0-my-change.patch

# Inspect producer CI
gh run list --workflow=build-and-release.yml --limit 5
gh run view <id> --log-failed