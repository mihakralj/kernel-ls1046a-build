# Rule: Canonical Tooling Paths

Use the existing scripts under `scripts/` rather than re-implementing their logic inline. They encode invariants and side-effects that are easy to get wrong by hand.

## Canonical scripts

| Script | Purpose |
|---|---|
| `scripts/patch-health.sh --source release` | Validate the patch set. Must report `Pass: 17`, `Fail: 0`, `0 SDK conflicts`, `266 files to install`. |
| `scripts/apply-to-tree.sh` | Apply patches AND copy verbatim SDK source drops into the kernel tree. Owns the 266-file SDK install invariant. |
| `scripts/run-pipeline.sh` | Full local build pipeline. Slow; use when verifying end-to-end. |
| `scripts/build-kernel.sh` | Kernel-only build step. |
| `scripts/build-ask-iptables.sh` / `build-ask-modules.sh` / `build-ask-ppp.sh` | Out-of-tree component builds. |
| `scripts/fetch-kernel.sh` | Refresh `work/linux-6.6.137.tar.xz` from upstream. |
| `scripts/normalize-patch.awk` | Normalize a `git diff` into the project's canonical patch format. ALWAYS pipe new patches through this. |
| `scripts/diff-vyos-config.sh` | Compare VyOS defconfig fragments vs an upstream reference. |
| `scripts/publish-binaries.sh` | Release artifact publishing. |
| `scripts/common.sh` | Shared bash helpers — source it; don't duplicate. |

> The previous derive/sync/reference-patch flow (`scripts/derive-patches.sh`, `fetch-reference.sh`, `fetch-upstream.sh`, `sync-upstream.sh`, `split-reference-patch.sh`, `publish-release.sh`) was retired in commit `bc38d90` ("redistribute: import ASK OOT module sources + userspace patches in-tree") when the producer pivoted away from `we-are-mono/ASK` reference-trees. Patches are now authored as direct edits against pristine `linux-6.6.137`; SDK sources are direct-edited under `/* ASK-edit (askNN): … */` markers (see `20-sdk-driver-rules.md`).

## Hard rules

1. **Do not duplicate script logic** in ad-hoc shell pipelines. Call the script.
2. **Patch generation flow** is fixed:
   ```
   git diff --no-prefix → scripts/normalize-patch.awk → release/patches/<bucket>/NNN-name.patch
   ```
3. **Do not bypass `scripts/apply-to-tree.sh`** when staging the kernel tree. The 266-file SDK install count is enforced through it.
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

# Audit ASK-edit markers in SDK source tree
grep -rln 'ASK-edit' release/patches/kernel/sdk-sources/