# lts_6.6_ls1046a — Agent Rules

Producer repo for the ASK kernel (`kernel-6.6.137-askN`). Builds Linux 6.6.137 + VyOS patches + NXP SDK DPAA/FMan/QBMan drivers and publishes a GitHub Release for the consumer `vyos-ls1046a-build` to pin against.

## Critical Build Workflow Rules

### Push the TAG ONLY for ASK iterations

For each new ask kernel iteration:

```bash
# Edit patches/code, run patch-health.sh --source release locally first
git commit -am '...'
git tag kernel-6.6.137-askN
git push origin kernel-6.6.137-askN      # ← TAG ONLY
```

**Do NOT** also push `lts-6.6-ls1046a` in the same `git push` command. The workflow triggers on BOTH ref types:

| Trigger | Behavior |
|---|---|
| `push: branches: [lts-6.6-ls1046a, main]` | Safety-net CI build, **no release** |
| `push: tags: [kernel-*]` | Build + **publishes Release** |

`git push origin lts-6.6-ls1046a kernel-6.6.137-askN` fires the workflow twice — once for the branch, once for the tag — wasting ~22 min of GitHub Actions minutes on a discarded redundant build. The `concurrency` group does not deduplicate them because branch and tag refs are distinct.

Push the branch ref only when you have **non-release** commits worth a CI sanity check (tooling, AGENTS.md, README, scripts) — and in that case do it BEFORE you cut the tag, in a separate push.

### Always run patch-health locally before tagging

```bash
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
bash scripts/patch-health.sh --source release
```

Must report `Pass: 21   Fail: 0` and `0 SDK conflicts (265 files to install)`. A clean `patch-health` is **not sufficient** — `git apply` may report success even when a patch's hunk count is wrong and lines get silently truncated. After patch-health, also visually inspect the affected file:

```bash
patch -p1 -d work/linux-6.6.137 < release/patches/ask/0X0-…patch
grep -n <expected-content> work/linux-6.6.137/<patched-file>
```

This caught the ask13 → ask14 hunk-count bug where `@@ -25,3 +25,6 @@` truncated 12 added lines to 6, silently dropping `obj-$(CONFIG_FSL_SDK_FMAN)` and `obj-$(CONFIG_FSL_SDK_DPAA_ETH)` from the Makefile, producing a kernel with neither sdk_fman nor sdk_dpaa built.

### Workflow file

`.github/workflows/build-and-release.yml` runs on `ubuntu-24.04-arm` (GitHub-hosted ARM64). Native build, ~22 min. **Tag pushes** publish a GitHub Release; **branch pushes** do not.

## Patch Inventory

Patches are organised in three buckets that mirror ASK-mono. Apply order
is `vyos/` → `ask/` → `fixes/`; within each bucket, sort by filename.

### `release/patches/vyos/` — VyOS deltas (apply first)

| # | Patch | Purpose |
|---|---|---|
| 001 | `vyos-linkstate-ip-device-attribute.patch` | VyOS link-state attr |
| 002 | `vyos-inotify-stackable-filesystems.patch` | VyOS inotify on overlayfs |
| 003 | `vyos-build-linux-perf-package.patch` | linux-perf .deb |

### `release/patches/ask/` — ASK fast-path (ASK-mono buckets, 010..080)

| # | Patch | Purpose |
|---|---|---|
| 010 | `ask-fman-dpaa-ehash.patch` | FMan/DPAA misc + SDK Kconfig+Makefile wiring |
| 020 | `ask-bridge-hooks.patch` | Bridge fast-path hooks (`abm_ff`, brevent notifier) |
| 030 | `ask-ipv4-ipv6-forwarding.patch` | IPv4/IPv6 forwarding fast-path |
| 040 | `ask-xfrm-ipsec-offload.patch` | IPsec offload (gated by `INET_IPSEC_OFFLOAD`) |
| 050 | `ask-conntrack-offload.patch` | Conntrack offload (`fp_info`, `qosconnmark`) |
| 060 | `ask-netfilter-qosmark.patch` | `comcerto_fp_netfilter.c` + xt_QOSMARK/QOSCONNMARK |
| 070 | `ask-ppp-hooks.patch` | PPP fast-path hooks |
| 080 | `wext-core-restore-ndo_do_ioctl.patch` | Wireless-extensions core restore |

### `release/patches/fixes/` — 6.6.y-specific repairs (090+)

| # | Patch | Purpose |
|---|---|---|
| 093 | `netlink-name-L2FLOW-cb-mutex.patch` | Lockdep mutex name (avoids dup name with NETLINK_GENERIC) |
| 094 | `swphy-10g-fixed-link.patch` | 10G fixed-link swphy support |
| 095 | `leds-lp5812-register.patch` | Register the lp5812 LED driver in `drivers/leds/Makefile` + `Kconfig` |
| 097 | `ask-fci-nlkey-narrow-gate.patch` | Adds `net/key/ask_fci_nlkey.c` + `CONFIG_ASK_FCI_NLKEY` to register `NETLINK_KEY=32` without enabling the (broken-on-6.6) IPsec offload data path |
| 099 | `dpaa-ethtool-quiet-no-phy.patch` | Demote the six remaining `netdev_err("phy device not initialized")` call sites in `sdk_dpaa/dpaa_ethtool.c` (`dpa_set_ksettings`, `dpa_nway_reset`, `dpa_get_pauseparam`, `dpa_set_pauseparam`, `dpa_get_eee`, `dpa_set_eee`) to `netdev_dbg`, matching the pre-existing pattern at the other two callsites. Boards with fixed-link / SFP+ cages (no `phylink`) legitimately have `mac_dev->phy_dev == NULL`; PHY-only ethtool ioctls were filling dmesg with dozens of identical KERN_ERR lines per VyOS interface commit. `-ENODEV` returns are unchanged so userspace still sees the op as unsupported |
| 101 | `stdlib-ext-fortify-port.patch` | (ask7) Drop 5 string prototypes (`strlen`, `strnlen`, `strcpy`, `strncpy`, `strtok`) from `sdk_fman/inc/stdlib_ext.h`. Mainline 6.6 defines these as `__builtin_choose_expr` macros via `<linux/fortify-string.h>`; redeclaring them as plain functions makes any TU that includes both fail with `expected identifier or '(' before '__builtin_choose_expr'` at `fortify-string.h:218`. Required for the lf-6.6.y SDK overlay to compile against stock `linux-6.6.137` |
| 102 | `arm64-ioremap-cache-ns-shim.patch` | (ask7, extended ask8) Two NXP-private arm64 helper aliases in `arch/arm64/include/asm/io.h`: `ioremap_cache_ns()` → `ioremap_cache()` (used by `bman_driver.c:194`, `qman_driver.c:451`) and `pgprot_cached_ns(prot)` → identity (used by `fsl_usdpaa.c:829`). NXP's lf-6.x defines both via `PROT_NORMAL_NS` / `PTE_NS` (Non-Secure TLB attr); mainline lacks both helpers and the attr. On this SoC running in EL2 the portals never traverse secure-world, so the cacheable / unchanged-prot mapping is a strict superset. Required for the lf-6.6.y SDK overlay to compile |
| 103 | `sdk-fman-ncsw-min-max-guard.patch` | (ask8) Guard `MIN()` / `MAX()` macros in `sdk_fman/inc/ncsw_ext.h` with `#ifndef`. Mainline 6.6 added `<linux/minmax.h>` to several headers transitively included by the SDK; redefinition produces `-Werror=macro-redefined` |
| 104 | `sdk-dpaa-mac-phylink-shims.patch` | (ask8) Two compile-time shims at the top of `sdk_dpaa/mac.c`: `#define PHY_INTERFACE_MODE_2500SGMII PHY_INTERFACE_MODE_2500BASEX` (NXP renamed in lf-6.x) and a static-inline `phylink_interface_max_speed()` returning `SPEED_10000` / `SPEED_2500` / `SPEED_1000` / `SPEED_100`. Mainline 6.6 lacks both; the SDK calls them in port-init paths gated by phylink |
| 105 | `sdk-dpaa-skb-recycle-shim.patch` | (ask8) Static-inline `skb_recycle()` shim at the top of `sdk_dpaa/dpaa_eth_sg.c`. The helper was removed from mainline before 6.6; SDK fast-path RX still calls it. Replicates the original semantics (release head state, zero shinfo up to dataref, set dataref=1, zero skb up to tail) |

> **ask7/ask8 build fixes (2026-05-03):** the lf-6.6.y SDK overlay required several thin compat shims to compile against stock `linux-6.6.137` (lf-6.6.y itself ships ~6.6.52 + NXP-private API extensions). ask7 introduced `fixes/101` and `fixes/102` (stdlib_ext fortify port + ioremap_cache_ns alias). ask7 CI then surfaced four more lf-6.6.y vs mainline-6.6.137 collisions covered by ask8: `pgprot_cached_ns` (folded into `fixes/102`), `MIN/MAX` redefinition (`fixes/103`), `phylink_interface_max_speed` + `PHY_INTERFACE_MODE_2500SGMII` (`fixes/104`), and `skb_recycle` (`fixes/105`). Whole-tree wet-run of `sdk_dpaa/`, `sdk_fman/`, `fsl_qbman/` produced 74 `.o` files with 0 errors. Shims are minimal and isolated — no behaviour change for non-SDK paths.

> **ask9 OOT module fix (2026-05-03):** ask8 CI built the kernel + SDK overlay clean but failed at the `--ask-extras` step (`scripts/build-ask-modules.sh`) with `cdx_common.h:18:10: fatal error: fm_ehash.h: No such file or directory`. The OOT `cdx` module (sourced from `we-are-mono/ASK` via `git archive`, 8 TUs `#include "fm_ehash.h"`) needs the `en_exthash_*` type definitions even though the kernel-side `FM_PCD_HashTableSet()` in lf-6.6.y never takes the EHASH branch. ask6 over-deleted the headers; ask9 restores **3 EHASH headers only** (no `.c`) by copying from the 6.6 reference (`mihakralj/ask-ls1046a-6.6` `main`): `fm_ehash.h` (1690 lines), `fm_eh_types.h` (52 lines), `fm_cc_dbg.h` (1378 lines). The kernel-side `Pcd/Makefile` from lf-6.6.y already does NOT list `fm_ehash.o`, so no kernel-side EHASH code is linked — Chain 2-B remains structurally unreachable per the ask6 doctrine. SDK file count: 262 → 265.

> **ask10 OOT module fix (2026-05-03):** ask9 CI got past the missing-header error but failed at compile of `work/ask-oot/src/cdx/devman.c` with five `-Werror=implicit-function-declaration` / `undeclared` errors against symbols only present in the lf-6.12.y SDK overlay used by ASK-mono — not in lf-6.6.y. Three of these are external-timestamp / EHASH (`extHashTsInfo`, `FM_PCD_UpdateExtTimeStamp`, `FM_PCD_GetExtTimeStampAddr`); the other two are sdk_dpaa helpers (`dpa_set_eth_ifinfo`, `dpa_update_eth_if`) that lf-6.12.y added but lf-6.6.y lacks. Fix: a new ask-modules patch `release/patches/ask-modules/02-cdx-lf66-stubs.patch` (a) comments out `#define INCLUDE_ETHER_IFSTATS 1` in `cdx/cdx_common.h` (the `dpa_set_eth_ifinfo` / `dpa_update_eth_if` calls live entirely inside `#ifdef INCLUDE_ETHER_IFSTATS` blocks and have no users elsewhere; the `INCLUDE_IFSTATS_SUPPORT` umbrella stays defined via VLAN/PPPoE/TUNNEL paths so `cdx_ifstats.c` keeps compiling); (b) stubs the bodies of `dpa_update_timestamp()` and `dpa_get_timestamp_addr()` in `cdx/devman.c` to no-ops, removing the references to `extHashTsInfo` / `FM_PCD_UpdateExtTimeStamp` / `FM_PCD_GetExtTimeStampAddr` / `EXTERNAL_TIMESTAMP_TIMERID`. PTP / external-timestamp is not used on the boot path. No kernel-side patch changes.

> **ask11 OOT module fix (2026-05-03):** ask10 CI advanced past the previous five errors but stopped at `work/ask-oot/src/cdx/devman.c:833` with `error: 'struct dpa_l2hdr_info' has no member named 'ether_stats_offset'`. The struct field at `cdx/cdx_common.h:257` is wrapped in `#ifdef INCLUDE_ETHER_IFSTATS`, so once ask10 commented that macro out the field disappeared. Three of the four `l2_info->ether_stats_offset = ...` writers in `devman.c` are correctly under `#ifdef INCLUDE_ETHER_IFSTATS` (lines 1108/1275/1526 in the post-ask10 numbering) but the writer at line 833 (inside the `IF_TYPE_ETHERNET` branch of `cdxdrv_get_l2hdr_info`) was missing the gate. Fix: extend `release/patches/ask-modules/02-cdx-lf66-stubs.patch` to wrap that single line in `#ifdef INCLUDE_ETHER_IFSTATS` / `#endif`, matching the pattern already in use at the three other write sites. Verified by `grep -nE "ether_stats_offset" cdx/devman.c` post-apply: all 4 writers preceded by an `#ifdef INCLUDE_ETHER_IFSTATS` line.


> **ask12 OOT module fix (2026-05-03):** ask11 CI cleared `devman.c` but failed in `work/ask-oot/src/cdx/cdx_ehash.c` with two errors: (1) `cdx_ehash.c:3301: error: too many arguments to function 'dpaa_eth_refill_bpools'` and (2) `cdx_ehash.c:2549: error: 'create_eth_rx_stats_hm' defined but not used [-Werror=unused-function]`. (1) lf-6.6.y `dpaa_eth_refill_bpools()` has signature `(struct dpa_bp *, int *count_ptr)` (confirmed in `release/patches/kernel/sdk-sources/drivers/net/ethernet/freescale/sdk_dpaa/dpaa_eth_sg.c:185` and `dpaa_eth.h:432`); the cdx caller had a third lf-6.12.y-only arg `CONFIG_FSL_DPAA_ETH_REFILL_THRESHOLD`. Fix: drop the third arg in the single call site at `cdx_ehash.c:3301`. (2) `create_eth_rx_stats_hm()` (decl L108, def L2549–2586) has all four call sites (lines 730/1215/2830/3433) wrapped in `#ifdef INCLUDE_ETHER_IFSTATS`; once ask10 commented that macro out, the function became unreachable and `-Werror=unused-function` fired. Fix: tag both forward decl and definition with `__maybe_unused`. Both edits extend `release/patches/ask-modules/02-cdx-lf66-stubs.patch`. Patch-health remains green: `Pass: 21  Fail: 0  0 SDK conflicts (265 files to install)`.

> **ask6 SDK refresh (2026-05-03):** `release/patches/kernel/sdk-sources/` was re-mirrored from `nxp-qoriq/linux` `lf-6.6.y` @ `e0f9e2afd4cf` (Makefile reports 6.6.52). The previous overlay was a 5.4.3-era drop that carried a broken `USE_ENHANCED_EHASH` machinery (`fm_ehash.c`, `en_exthash_info`, `copy_td_to_ccbase`, etc.) where `FM_PCD_HashTableSet()` returned a `t_FmPcdCcNode *` later reinterpret-cast as `en_exthash_info *`, NULL-derefing `dpa_app` at `copy_td_to_ccbase+0x68` during `FM_PCD_CcRootBuild()`. The lf-6.6.y SDK is what ASK-mono (lf-6.12.y) is authored against and contains no such code path. Net delta: 258 files replaced, 4 EHASH files deleted (`fm_ehash.c`, `fm_ehash.h`, `fm_eh_types.h`, `fm_cc_dbg.h`), 4 carry-overs preserved (`leds-lp5812.[ch]`, `dpaa_ethercat.c`, `fsl_oh_port.h`). Total SDK file count: 266 → 262 → 265 (ask9 restored 3 EHASH headers). Workarounds `fixes/098-fm-cc-ehash-redirect.patch` and `fixes/100-fm-cc-copy-td-null-guard.patch` were obsoleted and removed.

SDK source files (265 of them) are dropped under `release/patches/kernel/sdk-sources/` and copied into the kernel tree by `scripts/apply-to-tree.sh`. The 265 includes the lp5812 driver source pair, the dpaa_ethercat carry-over, and the fsl_oh_port.h header.

Patches in `fixes/` may target SDK-dropped files. `scripts/patch-health.sh` stages SDK sources into the kernel tree before the dry-run check so such patches validate cleanly.

## Driver Stack (the why behind ASK)

ASK ships **NXP SDK drivers**, not mainline:

| Symbol | Path | Mainline equivalent (NOT used) |
|---|---|---|
| `CONFIG_FSL_SDK_FMAN=y` | `drivers/net/ethernet/freescale/sdk_fman/` | `fman/` (`CONFIG_FSL_FMAN`) |
| `CONFIG_FSL_SDK_DPAA_ETH=y` | `drivers/net/ethernet/freescale/sdk_dpaa/` (fsl_mac, fsl_dpa) | `dpaa/` (`CONFIG_FSL_DPAA_ETH`) |
| `CONFIG_FSL_SDK_DPA=y` | `drivers/staging/fsl_qbman/` | `drivers/soc/fsl/qbman/` |

The SDK is required because mainline doesn't expose USDPAA / FMC / `dpa_ipsec` / `fmlib` userspace ABI consumed by the ASK userspace tools (`dpa_app`, `fmc`, etc).

Known SDK pitfall: `sdk_dpaa/mac.c:202` returns `-ENODEV` (not `-EPROBE_DEFER`) when `fm_bind()` finds FMan not yet probed. Mainline doesn't have this — it uses the component framework. Init order between `sdk_fman/` and `sdk_dpaa/` therefore matters; patch `ask/010`'s Makefile orders `sdk_fman/` first.

## Reference-Aligned Defconfig Invariants

The NXP/ASK 6.12 reference (`work/reference/config/kernel/defconfig`) ships `CONFIG_NET_KEY=y` (built-in), not `=m`. This is **load-bearing** for ASK: the NETLINK_KEY=32 socket that `cmm`'s `fci_open(FCILIB_KEY_TYPE)` requires is created from `af_key.c::ipsec_pfkey_init()`. With `CONFIG_NET_KEY=m`, `net/Makefile` enters `net/key/` via `obj-m += key/` (module-only descent), and any `obj-y` line inside `net/key/Makefile` is silently dropped — including our patch 097's `obj-$(CONFIG_ASK_FCI_NLKEY) += ask_fci_nlkey.o`. The kernel image then has no proto-32 registration, `cmm` fails with `EPROTONOSUPPORT`, and `cmm.service` cycle-restarts to a fake-active state.

Producer-side invariants discovered by ask49 vs reference comparison:

| Symbol | Reference (6.12) | This repo (must match) | Why |
|---|---|---|---|
| `CONFIG_NET_KEY` | `=y` | `=y` (in `release/vyos-base/10-networking.config`) | Required so `obj-y` items in `net/key/Makefile` are honored. |
| `CONFIG_INET_IPSEC_OFFLOAD` | `=y` | **must remain `=n`** on 6.6 | Reference path needs `xfrm_state` fields (`curr_time`, `offloaded`) that don't exist on 6.6.y. Re-enabling fails to compile. |
| `CONFIG_CPE_FAST_PATH` | `=y` | `=y` | ASK fast-path master gate; non-IPsec hooks are guarded by this. |
| `CONFIG_ASK_FCI_NLKEY` | n/a (reference uses NLKEY_SUPPORT inside af_key.c) | `=y` | Our 6.6 narrow-gate that registers proto 32 without pulling in the broken IPsec offload data path. |

ask50 (FCI fix) is therefore a **single-line defconfig change** flipping `CONFIG_NET_KEY=m` → `=y` in `release/vyos-base/10-networking.config`. Patch 097 is already correct.

## Two-chain failure model (post-ask49)

`ask-check` failures collapse into two **independent** chains. Knowing which one a symptom belongs to is critical for routing the fix.

### Chain 1 — kernel-side (this repo's responsibility)
- Symptoms: `cmm process running [FAILED]`, `cmm.service active [FAILED]`.
- Trigger: `socket(AF_NETLINK, SOCK_RAW, NETLINK_KEY=32) = -EPROTONOSUPPORT`.
- Diagnostic checklist on the running device:
  ```bash
  zcat /proc/config.gz | grep -E 'NET_KEY|ASK_FCI_NLKEY|INET_IPSEC_OFFLOAD'
  cat /proc/net/netlink | awk '{print $2}' | sort -u   # must include 32
  grep ask_fci /proc/kallsyms                          # must be non-empty
  ls /sys/module/ask_fci_nlkey 2>/dev/null             # must exist if =y
  dmesg | grep 'ASK FCI'
  ```

### Chain 2 — userspace-side (consumer `vyos-ls1046a-build` responsibility, NOT this repo)
- Symptoms: `dpa_app applied PCD configuration (failed rc=65280)`, `BMan fragment buffer pool located by CDX [FAILED]`, `no ASK driver probe/init/bind failures (≥1 hit(s))`.
- Sub-trigger A (MURAM exhaustion): `fm_cc.c:4377 AllocStatsObjs Memory Allocation Failed`.
  - Cause: `/etc/cdx_pcd.xml` requests ~16K stats objects in 384 KiB FMan MURAM; on-target `fmc` doesn't understand `external="yes" aging="yes"` and silently drops the DDR-offload directives, so hash tables fall back to MURAM and the allocator runs dry.
  - Fix lives in: `vyos-ls1046a-build` (rebuild `fmc`/`fmlib` from a tag that supports `external/aging`, and/or trim `cdx_pcd.xml` key counts).
- Sub-trigger B (NULL-deref in `copy_td_to_ccbase`, ARM64 oops at `+0x68`): the kernel-side path of an EHASH external-hash request was wired wrong in the vendored SDK — `FM_PCD_HashTableSet()` did not dispatch to `ExternalHashTableSet()` when `p_Param->externalHash` was set, so the returned `t_FmPcdCcNode *` was later reinterpret-cast as `en_exthash_info *` and the first field load NULL-deref'd. **Eliminated at producer level by ask6's SDK refresh** (see "ask6 SDK refresh" note above): the lf-6.6.y SDK does not carry the broken `USE_ENHANCED_EHASH` machinery at all, so `copy_td_to_ccbase` simply does not exist in the tree and the fault path is removed. Once a consumer pins ask6 or later, only sub-trigger A's userspace work remains.

The chains are independent: `fci.ko` does not register NETLINK_KEY (that is the in-tree `ask_fci_nlkey` `late_initcall`'s job), and `dpa_app` runs from `cdx_module_init` independent of `cmm`. Diagnose each chain separately and route fixes to the correct repo.

## Useful Commands

```bash
# Local sanity loop
bash scripts/patch-health.sh --source release       # validate patch set
bash scripts/run-pipeline.sh                        # full local build (slow)

# Watch producer CI
gh run list --workflow=build-and-release.yml --limit 5
gh run view <id> --log-failed

# Inspect a published release
gh release view kernel-6.6.137-askN