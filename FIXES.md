# Kernel 6.6.135 LTS Build Fixes for NXP LS1046A (DPAA1)

This document summarizes the patches applied to get the NXP LSDK DPAA1 SDK
sources (imported from `linux-5.15-rt`) to compile cleanly against the
upstream 6.6.135 LTS kernel on `aarch64` (target: LS1046A / Mono).

**Final green CI run:** [24769249669](https://github.com/mihakralj/lts_6.6_ls1046a/actions/runs/24769249669)
@ commit `3d4d300` on branch `lts-6.6-ls1046a` — runner `ubuntu-24.04-arm`.

The build enforces `-Werror=implicit-function-declaration` and
`-Werror=incompatible-pointer-types`, so every warning below had to be
resolved.

## Summary of API deltas (5.15 → 6.6)

| Old (5.15 / LSDK) | New (6.6) | Fix |
|---|---|---|
| `ioremap_cache_ns()` | removed | use `ioremap_cache()` |
| `pgprot_cached_ns()` | removed | use `pgprot_cached()` / drop entirely on arm64 |
| `pgprot_cached()` | not defined on arm64 | skip pgprot override in user mmap (default is already normal-cacheable) |
| `qman_create_portal(pcfg, cgrs)` | `qman_create_portal(pcfg, cgrs, need_cleanup)` | add `bool *need_cleanup` param |
| `qman_create_affine_portal(...)` | same — extra `bool *need_cleanup` | thread through |
| `qman_init_ccsr(node)` | `qman_init_ccsr(node, need_cleanup)` | thread through |
| `MIN` / `MAX` macros | now in `<linux/minmax.h>` | wrap SDK defs in `#ifndef` guards |
| `skb_recycle()` | removed | provide local no-op replacement |
| `t_Isr` typedef | stricter checking | cast `FM_EventIsr`/`FM_ErrorIsr` with `(t_Isr *)` |

## Commits (oldest → newest)

All patches live under `release/patches/kernel/sdk-sources/drivers/` and are
applied to the stock 6.6.135 tree during the build.

### Infrastructure / import
- **`383e268`** feat(kernel): rename LOCALVERSION from `-ask` to `-vyos`
- **`7ab4e7c`** enable `CONFIG_SFP=m`, `CONFIG_SENSORS_EMC2305=m` for Mono hardware
- **`e2e0f3a`** complete NXP LSDK SDK import from `linux-5.15-rt` (195 missing files)
- **`0c21af4`** ask-modules: import mono defensive-rewrite patch (6.6 compat)
- **`4f034ed`** restore `005-ask-sdk-kconfig-wiring.patch`

### `sdk_fman` (DPAA FMan driver)
- **`65b5391`** `fm_pcd_ext.h` — fix orphaned `#ifndef USE_ENHANCED_EHASH`
- **`8b90d7a`** `dpaa_eth_sg.c` — provide local `skb_recycle()` replacement
- **`4c2d352`** `fm_pcd.c` — restore `FM_PCD_HashTableSet` locals, guard
  external-hash `MissMonitorAddr` call
- **`5c4c798`** `fm_pcd.c` — simplify `FM_PCD_HashTableModifyMissMonitorAddr`
  to unconditional `E_NOT_SUPPORTED`
- **`0d84472`** `fm_port.h` — fix typo in `t_FmPort` member
  `internalFEBufferPoolAddr`
- **`9d6e5f0`** `fm.c` / `lnxwrp_sysfs_fm.c` — fix `fm_get_counter` duplicate
  prototype and add `(t_Isr *)` casts on `XX_SetIntr` / `FM_EventIsr` /
  `FM_ErrorIsr`
- **`8ba40fb`** `fm_muram.c` — define exported globals
  (`FmMurambaseAddr`, `FmMuramsize`), `#include <linux/slab.h>`,
  default `DBG_UCODE_RESVD_MURAM_SIZE`
- **`3784c3c`** `fm_ehash.c` — define `get_indexed_hash_bucket` locally as
  `static inline` (was `extern` with no definition — broke linking)
- **`3d4d300`** `fm_ehash.c` — `#include "crc64.h"` so `crc64_init` /
  `crc64_compute` (static inlines in that header) are visible at call sites
- **`5199f00`** `ncsw_ext.h` — guard `MIN` / `MAX` macros with
  `#ifndef` so they don't clash with 6.6's `<linux/minmax.h>`

### `fsl_qbman` (DPAA BMan / QMan driver)
- **`74f211b`** replace `ioremap_cache_ns()` → `ioremap_cache()`
  (the `_ns` variant does not exist on 6.6 arm64)
- **`6147211`** add `bool need_cleanup` parameter to prototypes of
  `qman_create_portal()` and `qman_create_affine_portal()`
- **`9bd7c6d`** thread `bool *need_cleanup` through `qman_init_ccsr()` and
  `init_pcfg()` call chain
- **`5199f00`** `fsl_usdpaa.c` — replace `pgprot_cached_ns` with
  `pgprot_cached` on arm64
- **`a692f00`** `fsl_usdpaa.c` — drop `pgprot_cached()` override on arm/arm64
  entirely (arm64 has no `pgprot_cached()`; default mmap prot is already
  normal-cacheable, which is what the driver wants)

## Notes

- `crc64_init()` / `crc64_compute()` in the SDK are private helpers living as
  `static __inline__` inside
  `drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/crc64.h`.
  They are **unrelated** to the kernel-wide `<linux/crc64.h>` (which
  provides `crc64_be()` etc.).
- Where possible, the fixes are conditional (`#ifdef CONFIG_ARM64` or
  `#ifndef FOO`) so the patches remain compatible with the original 5.15 tree
  and other architectures.
- No changes were made to the NXP-supplied ucode blobs or DPAA1 hardware
  init sequences — only C/preprocessor API-compat shims.

## Verification

```
$ gh run view 24769249669 --json status,conclusion
{"status":"completed","conclusion":"success"}
```

Build artifacts (kernel `Image`, modules, headers) produced on
`ubuntu-24.04-arm` GitHub-hosted runner, ~15–17 min per run.