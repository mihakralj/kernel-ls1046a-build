# lts_6.6_ls1046a — Agent Rules

Producer repo for the ASK kernel (`kernel-6.6.135-askN`). Builds Linux 6.6.135 + VyOS patches + NXP SDK DPAA/FMan/QBMan drivers and publishes a GitHub Release for the consumer `vyos-ls1046a-build` to pin against.

## Critical Build Workflow Rules

### Push the TAG ONLY for ASK iterations

For each new ask kernel iteration:

```bash
# Edit patches/code, run patch-health.sh --source release locally first
git commit -am '...'
git tag kernel-6.6.135-askN
git push origin kernel-6.6.135-askN      # ← TAG ONLY
```

**Do NOT** also push `lts-6.6-ls1046a` in the same `git push` command. The workflow triggers on BOTH ref types:

| Trigger | Behavior |
|---|---|
| `push: branches: [lts-6.6-ls1046a, main]` | Safety-net CI build, **no release** |
| `push: tags: [kernel-*]` | Build + **publishes Release** |

`git push origin lts-6.6-ls1046a kernel-6.6.135-askN` fires the workflow twice — once for the branch, once for the tag — wasting ~22 min of GitHub Actions minutes on a discarded redundant build. The `concurrency` group does not deduplicate them because branch and tag refs are distinct.

Push the branch ref only when you have **non-release** commits worth a CI sanity check (tooling, AGENTS.md, README, scripts) — and in that case do it BEFORE you cut the tag, in a separate push.

### Always run patch-health locally before tagging

```bash
rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/
bash scripts/patch-health.sh --source release
```

Must report `Pass: 16   Fail: 0` and `0 SDK conflicts (266 files to install)`. A clean `patch-health` is **not sufficient** — `git apply` may report success even when a patch's hunk count is wrong and lines get silently truncated. After patch-health, also visually inspect the affected file:

```bash
patch -p1 -d work/linux-6.6.135 < release/patches/ask/0X0-…patch
grep -n <expected-content> work/linux-6.6.135/<patched-file>
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
| 098 | `fm-cc-ehash-redirect.patch` | At the head of `FM_PCD_HashTableSet()`, dispatch external (DDR-resident) hash tables to `ExternalHashTableSet()` so the returned handle is `en_exthash_info *` — matching what `copy_td_to_ccbase()`, `FM_PCD_HashTableAddKey()`, etc. unconditionally cast it to. Without this redirect, `cdx_pcd.xml` `external="yes"` requests fall through to the in-MURAM CC-node path, the `t_FmPcdCcNode *` is later reinterpret-cast as `en_exthash_info *`, and `info->node->word_1` NULL-derefs in `copy_td_to_ccbase()` at `FM_PCD_CcRootBuild` time |

SDK source files (266 of them) are dropped under `release/patches/kernel/sdk-sources/` and copied into the kernel tree by `scripts/apply-to-tree.sh`. The 266 includes the lp5812 driver source pair.

Patches in `fixes/` may target SDK-dropped files (e.g. 098 patches `sdk_fman/Peripherals/FM/Pcd/fm_cc.c`). `scripts/patch-health.sh` stages SDK sources into the kernel tree before the dry-run check so such patches validate cleanly.

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
- Sub-trigger B (NULL-deref in `copy_td_to_ccbase`, ARM64 oops at `+0x68`): the kernel-side path of an EHASH external-hash request was wired wrong in the vendored SDK — `FM_PCD_HashTableSet()` did not dispatch to `ExternalHashTableSet()` when `p_Param->externalHash` was set, so the returned `t_FmPcdCcNode *` was later reinterpret-cast as `en_exthash_info *` and the first field load NULL-deref'd. **Fixed at producer level by `fixes/098-fm-cc-ehash-redirect.patch` (kernel-6.6.135-ask53).** Once a consumer pins ask53 or later, only sub-trigger A's userspace work remains.

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
gh release view kernel-6.6.135-askN