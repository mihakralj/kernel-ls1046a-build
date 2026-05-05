# Rule: Patch Authoring

All kernel modifications are expressed as patches in `release/patches/`, organized into **three buckets** applied in this order:

```
release/patches/vyos/        # 001..009  — VyOS deltas (apply first)
release/patches/ask/         # 010..080  — ASK fast-path (FMan, DPAA, bridge, IPv4/6, IPsec, conntrack, qosmark, PPP, wext)
release/patches/fixes/       # 090+      — 6.6.y-specific repairs and hotfixes
```

Within each bucket, patches are sorted by filename prefix. Numbering buckets are reserved — do NOT renumber across buckets.

SDK driver source files (NXP SDK, 266 of them) live under `release/patches/kernel/sdk-sources/<mirrored-path>` and are copied verbatim into the kernel tree by `scripts/apply-to-tree.sh`. They are NOT patches — never convert them to `.patch` form.

## Mandatory verification loop after ANY patch edit

A clean `patch-health.sh` is **necessary but not sufficient**: `git apply` can succeed while a malformed `@@` hunk header silently truncates added lines (this caused the ask13 → ask14 build, where 12 lines were truncated to 6 and `obj-$(CONFIG_FSL_SDK_FMAN)` / `obj-$(CONFIG_FSL_SDK_DPAA_ETH)` were silently dropped from the freescale Makefile).

After every patch edit, in order:

1. Re-extract a pristine kernel tree:
   ```bash
   rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
   ```
2. Run patch-health:
   ```bash
   bash scripts/patch-health.sh --source release
   ```
   Required result: `Pass: 25   Fail: 0`, `0 SDK conflicts`, `266 files to install`.
3. Visually verify the affected hunk(s):
   ```bash
   patch -p1 -d work/linux-6.6.137 < release/patches/<bucket>/<patch>
   grep -n '<expected-content>' work/linux-6.6.137/<patched-file>
   ```
4. Re-validate hunk headers: for each `@@ -a,b +c,d @@`, confirm
   - `b` == count of context + `-` lines in the hunk
   - `d` == count of context + `+` lines in the hunk

## Hunk header arithmetic (canonical reference)

```
@@ -OldStart,OldCount +NewStart,NewCount @@
```

- `OldCount` = number of lines beginning with ` ` (context) or `-` in the hunk body.
- `NewCount` = number of lines beginning with ` ` (context) or `+` in the hunk body.

When you change a hunk's content, recompute BOTH counts. Off-by-one in `NewCount` is the silent-truncation bug.

## Patch authoring procedure

1. Re-extract pristine tree from `work/linux-6.6.137.tar.xz`.
2. Apply all patches up to (but not including) your insertion point with `patch -p1`.
3. Edit target files in the working tree.
4. `git diff --no-prefix` (or `diff -uN`), pipe through `scripts/normalize-patch.awk`.
5. Save with the next sequential prefix in the correct bucket.
6. Run the verification loop above.

## Forbidden

- Mixing two unrelated logical changes in one patch.
- Re-using an existing patch number for a different change.
- Editing files under `release/patches/kernel/sdk-sources/` to "fix" SDK behavior — those are verbatim NXP drops; fix via an `ask/` or `fixes/` patch instead.
- Relaxing `patch-health.sh` thresholds to make a build pass.