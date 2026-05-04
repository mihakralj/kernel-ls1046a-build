# FIX-PLAN-ASK18 — clear all open issues from ask17

## 1. Status quo (ask17, CI run `25296223419`)

`patch-health` passes (`Pass: 21  Fail: 0  0 SDK conflicts (265 files to install)`); kernel + SDK overlay compile cleanly; cdx OOT module compiles cleanly. Build fails at **modpost** with exactly **10 unresolved symbols** plus **1 section-mismatch warning**:

```
WARNING: modpost: cdx: section mismatch in reference: cdx_ctrl_deinit+0x24 (.text) -> cdx_cmdhandler_exit (.exit.text)
ERROR: modpost: "FM_PORT_PcdPlcrAllocProfiles"     [cdx.ko] undefined
ERROR: modpost: "FM_VSP_Config"                    [cdx.ko] undefined
ERROR: modpost: "FM_VSP_ConfigBufferPrefixContent" [cdx.ko] undefined
ERROR: modpost: "FM_MURAM_AllocMem"                [cdx.ko] undefined
ERROR: modpost: "qman_sp_enable_ceetm_mode"        [cdx.ko] undefined
ERROR: modpost: "FM_PORT_SetOhPortOfne"            [cdx.ko] undefined
ERROR: modpost: "get_ip_reassem_info"              [cdx.ko] undefined
ERROR: modpost: "ExternalHashTableAllocEntry"      [cdx.ko] undefined
ERROR: modpost: "ExternalHashTableEntryFree"       [cdx.ko] undefined
ERROR: modpost: "ExternalHashTableFmPcdHcSync"     [cdx.ko] undefined
```

Why the per-iteration TU-stub strategy that worked for ask10..ask17 stops here: those stubs were `static inline`, which has **internal linkage**. They satisfied the C front-end's prototype check and folded away if unreferenced. **modpost looks at the linked `.ko` object and only sees real `EXTERN` references that don't resolve to any `EXPORT_SYMBOL` in the kernel.** No amount of `static inline` in cdx TUs reaches modpost; the fix has to live on the kernel-side or in a non-static cdx wrapper TU.

## 2. Root-cause classification (verified against the lf-6.6.y SDK in tree)

| # | Symbol | Class | Defined in lf-6.6.y? | EXPORT'd? | Fix path |
|---|---|---|---|---|---|
| 1 | `FM_PORT_PcdPlcrAllocProfiles` | A | yes — `sdk_fman/Peripherals/FM/Port/fm_port.c:4530` | ❌ | add `EXPORT_SYMBOL` |
| 2 | `FM_VSP_Config` | A | yes — `sdk_fman/Peripherals/FM/SP/fm_sp.c:408` | ❌ | add `EXPORT_SYMBOL` |
| 3 | `FM_VSP_ConfigBufferPrefixContent` | A | yes — `sdk_fman/Peripherals/FM/SP/fm_sp.c:578` | ❌ | add `EXPORT_SYMBOL` |
| 4 | `FM_MURAM_AllocMem` | A | yes — `sdk_fman/Peripherals/FM/fm_muram.c:121` | ❌ | add `EXPORT_SYMBOL` |
| 5 | `qman_sp_enable_ceetm_mode` | A | yes — `staging/fsl_qbman/qman_config.c:954` | ❌ | add `EXPORT_SYMBOL_GPL` |
| 6 | `FM_PORT_SetOhPortOfne` | B | **no** (lf-6.12.y addition) | n/a | non-static stub in compat TU |
| 7 | `get_ip_reassem_info` | B | **no** (lf-6.12.y addition) | n/a | non-static stub in compat TU |
| 8 | `ExternalHashTableAllocEntry` | C | **no** (deleted in ask6 EHASH purge) | n/a | gate callsites under `#ifdef USE_ENHANCED_EHASH` (off) |
| 9 | `ExternalHashTableEntryFree` | C | **no** (deleted in ask6 EHASH purge) | n/a | gate callsites under `#ifdef USE_ENHANCED_EHASH` (off) |
| 10 | `ExternalHashTableFmPcdHcSync` | C | **no** (deleted in ask6 EHASH purge) | n/a | gate callsites under `#ifdef USE_ENHANCED_EHASH` (off) |

The section-mismatch warning is independent: `cdx_ctrl_deinit()` (in `.text`) calls `cdx_cmdhandler_exit()` which is marked `__exit` (in `.exit.text`). Modpost flags this because `__exit`-tagged code can be discarded after init; calls to it from non-`__exit` paths risk dereferencing freed text. Either drop `__exit` from `cdx_cmdhandler_exit` or mark the call path with `__ref`.

## 3. Plan — three coordinated changes shipped together as ask18

The single common-mode reason ask10..ask17 each only chipped at one error per round is that we treated each TU's compile failure in isolation. ask18 must be a **single tag** that contains all three coordinated fixes; otherwise modpost will keep failing on whichever class is left unaddressed.

### 3.1 Class A — kernel-side `EXPORT_SYMBOL` patch

**New file:** `release/patches/fixes/106-sdk-export-symbols-for-cdx-oot.patch`

Adds `EXPORT_SYMBOL` (or `EXPORT_SYMBOL_GPL` to match the surrounding qbman convention) immediately after each function definition in the SDK source files. Five hunks across three files:

- `drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Port/fm_port.c` — after `FM_PORT_PcdPlcrAllocProfiles` (closing `}` of function ending around line 4540s).
- `drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/SP/fm_sp.c` — after `FM_VSP_Config` and `FM_VSP_ConfigBufferPrefixContent`.
- `drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/fm_muram.c` — after `FM_MURAM_AllocMem`.
- `drivers/staging/fsl_qbman/qman_config.c` — after `qman_sp_enable_ceetm_mode` (use `_GPL` here — qbman exports use the GPL variant).

Verification:
```bash
nm -D work/linux-6.6.137/vmlinux 2>/dev/null | grep -E ' T (FM_PORT_PcdPlcrAllocProfiles|FM_VSP_Config|FM_VSP_ConfigBufferPrefixContent|FM_MURAM_AllocMem|qman_sp_enable_ceetm_mode)$'
# must show all 5 as global text
```

Risk: zero. These are NXP-private API surface areas the SDK already documents and exports in lf-6.12.y; lf-6.6.y simply forgot. We are restoring parity, not inventing exports.

### 3.2 Class B — non-static compat wrapper TU

**New file:** `release/patches/ask-modules/03-cdx-lf66-compat-tu.patch`

Adds a NEW translation unit `cdx/lf66_compat.c` and updates the cdx `Makefile` (also part of the OOT archive) to compile it. Contents:

```c
/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * lf66_compat.c — non-static stubs for lf-6.12.y SDK helpers absent in
 * lf-6.6.y. The cdx OOT references these on cold paths (offline-port
 * external-fne setup; IP reassembly info getter); both bodies are
 * unreachable from the boot/cmm path on this board, so a stub is safe.
 */
#include <linux/types.h>
#include <linux/printk.h>

/* fm_port_ext.h prototype in lf-6.12.y; absent in lf-6.6.y. */
int FM_PORT_SetOhPortOfne(void *h_FmPort, void *p_OhFnePrm)
{
        (void)h_FmPort; (void)p_OhFnePrm;
        return 0;  /* E_OK */
}
EXPORT_SYMBOL(FM_PORT_SetOhPortOfne);

/* dpaa_eth.h prototype in lf-6.12.y; absent in lf-6.6.y. */
void *get_ip_reassem_info(void *net_dev)
{
        (void)net_dev;
        return NULL;
}
EXPORT_SYMBOL(get_ip_reassem_info);
```

Move the corresponding `static inline` shims out of `02-cdx-lf66-stubs.patch` (where they currently live for ask10..ask17 callsites that don't include `lf66_compat.c`) — they become redundant once the real symbols exist with external linkage.

The exact prototypes must match the cdx callers: open `work/ask-oot/src/cdx/devoh.c` after extraction and copy the literal call signature; keep the param types identical to avoid `-Werror=incompatible-pointer-types`.

Verification:
```bash
nm work/ask-oot/src/cdx/cdx.ko | grep -E ' T (FM_PORT_SetOhPortOfne|get_ip_reassem_info)$'
# must show both as defined in cdx.ko itself
```

### 3.3 Class C — EHASH callsite gating

**Extends:** `release/patches/ask-modules/02-cdx-lf66-stubs.patch` with a new hunk that defines `USE_ENHANCED_EHASH` to `0` (or wraps the three callsites in `#ifdef USE_ENHANCED_EHASH … #endif` and leaves the macro undefined) at the top of every cdx TU that calls `ExternalHashTable*`. Find them with:

```bash
grep -rn "ExternalHashTableAllocEntry\|ExternalHashTableEntryFree\|ExternalHashTableFmPcdHcSync" \
  work/ask-oot/src/cdx/*.c
```

Per the ask6 doctrine, EHASH is structurally unreachable on this kernel: the lf-6.6.y SDK has no `t_FmPcdCcNode → en_exthash_info` reinterpret path, and the kernel-side `Pcd/Makefile` does not build `fm_ehash.o`. Removing the calls from the cdx side completes the symmetry.

Alternative tactical option (only if 3.2 is taken): add three more no-op stubs to `lf66_compat.c`:
```c
int ExternalHashTableAllocEntry(void *a, void *b)        { (void)a; (void)b; return -1; }
int ExternalHashTableEntryFree(void *a)                   { (void)a; return -1; }
int ExternalHashTableFmPcdHcSync(void *a)                 { (void)a; return -1; }
EXPORT_SYMBOL(ExternalHashTableAllocEntry);
EXPORT_SYMBOL(ExternalHashTableEntryFree);
EXPORT_SYMBOL(ExternalHashTableFmPcdHcSync);
```
Choose **gating** over **stubbing** unless the call sites are not gateable without further `-Werror=unused-function` cascades. Default plan: gate.

### 3.4 Section-mismatch warning (deferrable)

Pick one of:

- **Quickest:** strip the `__exit` annotation from `cdx_cmdhandler_exit` in `02-cdx-lf66-stubs.patch`. One-line change, no behaviour delta.
- **Cleanest:** annotate `cdx_ctrl_deinit` with `__ref` so modpost knows the call is intentional.

Not blocking — it's a `WARNING:`, not an `ERROR:`, but cleaning it now avoids future signal noise.

## 4. Sequenced execution checklist

```
- [ ] 1. Snapshot: confirm patch-health green on the current ask17 tree
        rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
        bash scripts/patch-health.sh --source release   # Pass: 21  Fail: 0

- [ ] 2. Author Class A patch (fixes/106-sdk-export-symbols-for-cdx-oot.patch)
        - 5 EXPORT_SYMBOL hunks, normalized via scripts/normalize-patch.awk
        - Re-extract pristine + patch-health: must report Pass: 22  Fail: 0

- [ ] 3. Author Class B compat TU
        - extract OOT cdx archive locally (scripts/build-ask-modules.sh dry-run)
        - read literal prototypes from devoh.c, cdx_reassm.c
        - create lf66_compat.c with EXPORT_SYMBOL on both stubs
        - update cdx Makefile (in OOT archive) to compile lf66_compat.o
        - ship as release/patches/ask-modules/03-cdx-lf66-compat-tu.patch
        - remove now-redundant static inline duplicates from 02-cdx-lf66-stubs.patch

- [ ] 4. Class C EHASH gating
        - identify 3 callsites with grep
        - extend 02-cdx-lf66-stubs.patch with #ifdef USE_ENHANCED_EHASH gates
        - confirm no -Werror=unused-function fallout

- [ ] 5. Section-mismatch cleanup
        - drop __exit from cdx_cmdhandler_exit OR annotate caller __ref
        - extend 02-cdx-lf66-stubs.patch

- [ ] 6. Local validation loop
        - rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
        - bash scripts/patch-health.sh --source release   (Pass: 22  Fail: 0)
        - bash scripts/run-pipeline.sh                    (full ARM64 build)
        - confirm work/output contains kernel tarball + cdx.ko + no modpost ERRORs

- [ ] 7. Visual hunk re-verification per .clinerules/10-patch-authoring.md
        - re-apply each new patch by hand
        - grep for added EXPORT_SYMBOL lines in target SDK files
        - validate every @@ -a,b +c,d @@ arithmetic

- [ ] 8. AGENTS.md narrative entry for ask18
        - one paragraph following the ask6..ask17 cadence
        - call out that this iteration moves from compile-fix-per-tag to
          coordinated link-fix and is structurally different from prior ones

- [ ] 9. Commit boundaries (per .clinerules/40-commit-style.md)
        - commit 1: fixes: add EXPORT_SYMBOL for cdx-consumed SDK helpers (106)
        - commit 2: ask: add lf66_compat TU for missing lf-6.12.y helpers (03)
        - commit 3: ask: gate EHASH callsites in cdx OOT
        - commit 4: ask: silence cdx_ctrl_deinit __exit section mismatch
        - commit 5: docs: AGENTS.md ask18 narrative + manifest bump
        - commit 6: release: bump release/manifest.json ask_iteration → ask18

- [ ] 10. Tag & publish per .clinerules/00-tag-discipline.md
        - git tag kernel-6.6.137-ask18
        - git push origin kernel-6.6.137-ask18         # TAG ONLY
        - DO NOT include lts-6.6-ls1046a in the same push
        - watch: gh run watch <id> --exit-status
```

## 5. Acceptance criteria

ask18 is "done" when **all** of the following hold:

1. `scripts/patch-health.sh --source release` reports `Pass: 22  Fail: 0  0 SDK conflicts` and `265 files to install` (file count unchanged — no new SDK drops).
2. CI run for `kernel-6.6.137-ask18` completes successfully on `ubuntu-24.04-arm`.
3. The published `kernel-6.6.137-ask18` GitHub Release contains `kernel-tarball.tar.xz`, `headers.tar.xz`, `modules.tar.xz`, and `ask-modules.tar.xz` (the latter contains a non-empty `cdx.ko`).
4. `nm cdx.ko | grep ' U '` shows zero unresolved symbols (modpost having passed implies this, but spot-check).
5. `nm cdx.ko | grep -E ' T (FM_PORT_SetOhPortOfne|get_ip_reassem_info)$'` shows both as defined within `cdx.ko`.
6. `nm vmlinux | grep -E ' T (FM_PORT_PcdPlcrAllocProfiles|FM_VSP_Config|FM_VSP_ConfigBufferPrefixContent|FM_MURAM_AllocMem|qman_sp_enable_ceetm_mode)$'` shows all five as defined.
7. No new modpost ERRORs or WARNINGs vs ask17 (the section-mismatch warning fixed; nothing new introduced).
8. The original section-mismatch warning is gone.

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Class A `EXPORT_SYMBOL` macro symbol collision (already exported under a different name) | low | low | local `nm vmlinux` check before tag; the SDK uses singular `T`, not weak |
| Class B prototype mismatch — caller signature drift between lf-6.12.y and our stub | medium | medium (compile fail) | grep call signatures in `work/ask-oot/src/cdx/devoh.c`, `cdx_reassm.c` and copy verbatim |
| Class C gating leaves a dangling `else` or trailing comma in the cdx TU | low | low | post-patch grep for the gated regions; visual inspection per `.clinerules/10` |
| New OOT TU `lf66_compat.c` not seen by the cdx Makefile | medium | high (no improvement) | confirm `obj-m += lf66_compat.o` lands; observe `CC [M] lf66_compat.o` in next CI log |
| `qman_sp_enable_ceetm_mode` `EXPORT_SYMBOL` vs `EXPORT_SYMBOL_GPL` choice rejected by license header | low | low | match the file's existing convention (qbman uses GPL) |
| Patch-health pass count expected to stay 21 but Class A patch lands in `fixes/` | guaranteed | informational | update the `Pass: 21 → 22` invariant in `.clinerules/50-thresholds-are-authoritative.md` and `AGENTS.md` |

## 7. What NOT to do (anti-patterns we already drifted into)

- **Don't** keep adding `static inline` no-ops in cdx TUs. They are invisible to modpost. Anything that needs to satisfy modpost needs **external linkage** — either kernel-side `EXPORT_SYMBOL` or a non-static definition in a cdx-build-included TU.
- **Don't** edit `release/patches/kernel/sdk-sources/` directly to add `EXPORT_SYMBOL`. Per `.clinerules/10-patch-authoring.md`, SDK source drops are verbatim NXP. The fix is a `fixes/` patch that runs after `apply-to-tree.sh` copies the verbatim files in.
- **Don't** restore the `fm_ehash.c` source file or `USE_ENHANCED_EHASH` machinery. ask6 deliberately deleted the broken NULL-deref path; the correct closure is to delete callers, not resurrect callees.
- **Don't** push `lts-6.6-ls1046a` and `kernel-6.6.137-ask18` in the same `git push`. Tag-only, per `.clinerules/00-tag-discipline.md`.
- **Don't** loosen `patch-health.sh` thresholds to mask anything. The threshold goes from 21 → 22 because we add one new patch (`fixes/106`); update the invariant in lockstep, don't relax it.
- **Don't** mix consumer-side fixes (MURAM exhaustion, `cdx_pcd.xml` trim, `fmc`/`fmlib` rebuild) into ask18. Those belong in `/root/vyos-ls1046a-build`. Keep ask18 pure producer-side modpost closure.

## 8. Stretch goal — once ask18 ships

When ask18 produces a valid artifact, immediately bump `/root/vyos-ls1046a-build/data/ask-kernel.pin` to `kernel-6.6.137-ask18`, rebuild the consumer, and re-collect `emmc_boot.log`. The expected diff vs the current `emmc_boot.log`:

- The 30× `phy device not initialized` lines should disappear (already fixed since ask3 via `fixes/099`).
- The Chain-2 MURAM exhaustion + `dpa_app rc=65280` symptoms remain — those are still consumer-repo work (`fmc`/`fmlib` + `cdx_pcd.xml` trim).

This boot-log baseline is the empirical confirmation that ask18 closes Chain 1; everything that remains is by definition Chain 2 and must be routed to the consumer repo.