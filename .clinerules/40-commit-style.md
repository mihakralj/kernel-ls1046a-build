# Rule: Commit & Tag Message Style

## Subject prefixes

Every commit subject must begin with one of these scope prefixes, matching the area of change:

| Prefix | Scope |
|---|---|
| `ask:` | Anything under `release/patches/ask/` or ASK fast-path behavior. |
| `vyos:` | `release/patches/vyos/` or VyOS defconfig fragments under `release/vyos-base/`. |
| `fixes:` | `release/patches/fixes/` (6.6.y repairs / hotfixes). |
| `sdk:` | `release/patches/kernel/sdk-sources/` (verbatim NXP SDK drops). |
| `scripts:` | `scripts/`. |
| `ci:` | `.github/workflows/`. |
| `docs:` | `README.md`, `AGENTS.md`, `FIX-PLAN-*.md`, `BUILD-COMPARISON.md`, `FIXES.md`, `.clinerules/`. |
| `release:` | `release/manifest.json` askN bumps, release-only metadata. |

## Rules

1. **One logical change per commit.** Don't combine a patch edit with a manifest bump or a script change.
2. **Patch reorderings are their own commits** with `ask:` / `fixes:` prefix and a body explaining why the order changed.
3. **Defconfig diffs** must be surfaced in the commit body — paste the `scripts/diff-vyos-config.sh` output.
4. **Tag annotations** for `kernel-6.6.137-askN` must list the deltas vs the prior askN (commits, patch additions/edits, defconfig changes, manifest bumps).
5. **No `WIP`, `fixup!`, or `squash!` commits on `lts-6.6-ls1046a`.** Squash locally before pushing.

## Example

```
ask: order sdk_fman/ before sdk_dpaa/ in freescale Makefile

sdk_dpaa/mac.c:202 returns -ENODEV (not -EPROBE_DEFER) when fm_bind()
finds FMan unprobed. The component-framework path used by mainline
isn't present, so build/link order is the only ordering signal.

Fixes the silent boot failure observed on ask13 where neither
sdk_fman nor sdk_dpaa initialized.

patch-health: Pass: 13 Fail: 0, 0 SDK conflicts, 264 files to install.