# Build process comparison: pre-ASK (early Apr 2026) vs current ASK pipeline

Reference points:
- **Pre-ASK** = `mihakralj/vyos-ls1046a-build` @ commit `2b82845` (release `2026.04.10-0547-rolling`, last green Mono boot)
- **Current ASK** = `mihakralj/vyos-ls1046a-build` @ `main` (post-PR #31/#32) + `mihakralj/lts_6.6_ls1046a` @ `main` (kernel producer)

---

## 1. Number of repos

| | Pre-ASK | Current |
|---|---|---|
| Repos involved | **1** (`vyos-ls1046a-build`) | **2** (`vyos-ls1046a-build` consumer + `lts_6.6_ls1046a` producer) |
| Kernel built where | Inline, in the same workflow that builds the ISO | Separate workflow in producer; consumer downloads prebuilt `.deb`s |
| Reproducibility | Single repo, single commit → one ISO | Consumer + producer must be jointly versioned (pin file `data/ask-kernel.pin`) |

---

## 2. CI workflow steps (in order)

### Pre-ASK `auto-build.yml`

```
1. Install Dependencies
2. Checkout vyos-ls1046a-build
3. ci-set-version.sh                  # version env vars
4. Checkout vyos-build (upstream)
5. ci-setup-vyos1x.sh                 # vyos-1x patches
6. ci-setup-kernel.sh                 # ★ patches + config fragments INTO vyos-build's
                                      #   linux-kernel package, then VyOS builds it
7. ci-setup-vyos-build.sh             # chroot files / hooks / DTB / serial fixups
8. Build Image Packages               # vyos-build builds linux-kernel + vyos-1x .debs
9. Pick Packages
10. ci-install-extra-packages.sh
11. Build VyOS ISO
12. Upload artifact / publish release
```

### Current `auto-build.yml`

```
1. Verify Hardware (self-hosted)      # NEW — runs on physical Mono builder
2. Relocate workspace to NVMe         # NEW
3. Install Dependencies
4. Checkout vyos-ls1046a-build
5. ci-set-version.sh
6. Checkout vyos-build
7. ci-setup-vyos1x.sh
8. ci-consume-ask-kernel.sh           # ★★ NEW — pulls prebuilt kernel .debs
                                      #   from lts_6.6_ls1046a release tag
9. ci-setup-kernel.sh                 # ★ NOW A NO-OP for kernel build
                                      #   (linux-kernel package SKIPPED below)
10. Checkout ASK repo (ask-ls1046a-6.6)
11. ci-setup-kernel-ask.sh            # NEW — stages SDK DPAA hooks
12. ci-setup-vyos-build.sh            # chroot files / hooks / DTB / serial fixups
13. Build Image Packages              # ★★ kernel build SKIPPED in ASK mode
                                      #   (env ASK_KERNEL_TAG short-circuits)
14. Pick Packages                     # ASK-aware kernel-presence check
15. ci-install-extra-packages.sh
16. Build VyOS ISO
17. Upload artifact / publish release
```

**Net change to the script-call order**: insert `ci-consume-ask-kernel.sh` and `ci-setup-kernel-ask.sh` between vyos-1x setup and vyos-build setup; everything downstream is the same shape but ASK-aware.

---

## 3. How the kernel is produced

### Pre-ASK (single repo, in-line build)

```
   VyOS upstream vyos_defconfig (3000 lines)
 + data/kernel-config/ls1046a-board.config       (sensors)
 + data/kernel-config/ls1046a-dpaa1.config       (DPAA, FMAN, BMAN, QMAN, SERIAL_OF_PLATFORM)
 + data/kernel-config/ls1046a-i2c-gpio.config
 + data/kernel-config/ls1046a-network-perf.config
 + data/kernel-config/ls1046a-sfp.config
 + data/kernel-config/ls1046a-usb.config
 + data/kernel-config/ls1046a-watchdog.config
 → make vyos_defconfig
 → vyos-build/scripts/package-build/linux-kernel/build-kernel.sh
   ├─ patch 4002-hwmon-ina2xx-add-INA234-support
   ├─ patch 4003-sfp-rollball-phylink-einval-fallback
   ├─ patch 4004-swphy-support-10g-fixed-link-speed
   ├─ inject patch-phylink.py runtime patcher
   ├─ inject patch-dpaa-xdp-queue-index.py
   └─ inject fsl_fmd_shim.c (chardev for DPDK fmlib)
 → linux-image-<KVER>-vyos.deb (mainline DPAA driver)
```

### Current ASK (split, prebuilt kernel + hooks)

Producer (`lts_6.6_ls1046a`):
```
   VyOS-snapshot release/vyos-base/arm64/vyos_defconfig (3000 lines, includes SERIAL_OF_PLATFORM)
 + release/vyos-base/*.config         (filesystems, networking, netfilter…)
 + release/ask.config                 (LS1046A/DPAA delta, wins last)
 → scripts/kconfig/merge_config.sh
 → scripts/apply-to-tree.sh applies, in order:
   ├─ 001-vyos-linkstate-ip-device-attribute
   ├─ 002-vyos-inotify-stackable-filesystems
   ├─ 003-vyos-build-linux-perf-package
   ├─ 004-ask-kernel-hooks                  ← DPAA/FMan SDK hooks
   └─ 005-ask-sdk-kconfig-wiring
   Plus: copy 67 SDK source files (release/patches/kernel/sdk-sources/) into tree
 → make olddefconfig → builds .debs → publishes GitHub Release tag kernel-6.6.135-askN
```

Consumer (`vyos-ls1046a-build`):
```
 ci-consume-ask-kernel.sh:
   curl GH API for release tag (data/ask-kernel.pin)
   → linux-image-<KVER>-vyos.deb (SDK DPAA driver)
   → drop into vyos-build/data/live-build-config/packages.chroot/
   → live-build dpkg -i installs them into the rootfs
```

---

## 4. What is **functionally** different in the bits that ship

| Component | Pre-ASK | Current | Boot-impacting? |
|---|---|---|---|
| Kernel base | linux-6.6.y stable (via vyos-build) | linux-6.6.135 (NXP ASK base) | mostly equivalent |
| DPAA driver | Mainline `drivers/net/ethernet/freescale/dpaa/` | NXP SDK `drivers/net/ethernet/freescale/sdk_dpaa/` (much larger, with FMD/CEETM) | networking only — not boot |
| Kernel CONFIG_SERIAL_OF_PLATFORM | y (added by `ls1046a-dpaa1.config` fragment) | y (already in `release/vyos-base/arm64/vyos_defconfig`) | **identical → not the regression** |
| Kernel CONFIG_SERIAL_8250_FSL | y (VyOS stock) | y (VyOS stock) | identical |
| `mono-gw.dtb` | Built once, committed: 92452 B, md5 `d9e33cdc…` | **Same byte-identical 92452-B blob still committed** until PR #32 | **★ THIS WAS THE REGRESSION** |
| `mono-gateway-dk.dts` | No DWC3 quirks | **Adds** `snps,dis_u2/u3_susphy_quirk`, `snps,dis-u1/u2-entry-quirk`, `/delete-property/ usb3-lpm-capable` (with explicit comment: required for live-boot from USB) | `.dts` was modified but `.dtb` was never recompiled |
| DTB rebuild in CI | None — just `cp data/dtb/mono-gw.dtb` | Conditional `make freescale/mono-gateway-dk.dtb` in `ci-build-packages.sh`, but only when `package == linux-kernel` (i.e. *never* in ASK consume mode), and wrapped in `\|\| true` | **silent fallback to the stale committed DTB** |
| Userspace fast-path tools | DPDK PMD path (now archived) | `cdx.ko`, `fci.ko`, `auto_bridge.ko`, `cmm`, `dpa_app`, `libcli`, `libfci`, `fmc`, `fmlib` from `ask-ls1046a-6.6` | userspace only |

---

## 5. Why the current build threw the kernel panic

The panic seen on Mono:

```
Warning: unable to open an initial console
Kernel panic - not syncing: Attempted to kill init!
```

is **not** a kernel-config or serial-driver regression. Evidence:

1. `CONFIG_SERIAL_OF_PLATFORM=y` is present in the producer `vyos_defconfig` (line 3000). It is also present in the merged ASK config after `make olddefconfig`. The pre-ASK overlay added the *same* single line on top of VyOS stock. → **Serial layer is functionally equivalent.**

2. The DTB shipped in the ISO (`includes.binary/mono-gw.dtb` and `includes.chroot/boot/mono-gw.dtb`) was the **stale 92 KB blob committed in `data/dtb/mono-gw.dtb`** (md5 `d9e33cdcb33332d16eecc9445b7e2dc1`, identical to the pre-ASK blob). CI run [24801876163](https://github.com/mihakralj/vyos-ls1046a-build/actions/runs/24801876163) shows only `cp data/dtb/mono-gw.dtb …` — **no `make freescale/mono-gateway-dk.dtb` step ran** because that step is gated on building the `linux-kernel` package locally, which is skipped in ASK consume mode.

3. The `.dts` source was updated weeks ago to add DWC3 USB stability quirks. The DTS comment block explicitly states they are required for live-boot from USB stick:

   > "Without these, high-speed USB-2 mass storage (live-boot USB stick) enumerates but cannot sustain bulk transfers during initramfs filesystem scan — the port resets every ~30s with `xhci-hcd: Setup ERROR: setup context command for slot N` / `usb 1-1: hub failed to enable device, error -22` and live-boot **never finds filesystem.squashfs**."

4. With no `filesystem.squashfs` mountable, live-boot has no rootfs, cannot exec `/sbin/init`, and the kernel panics with `Attempted to kill init!`. The `unable to open an initial console` line is a downstream side effect, not the cause.

So the regression is the **interaction of two changes**:

- **A**: developer added DWC3 quirks to `.dts` but did not regenerate the committed `.dtb`.
- **B**: the build pipeline switched to ASK consume mode, which bypasses the in-tree DTB rebuild step that *might* have caught (A) — and even when not bypassed, it was wrapped in `\|\| true` so a failure would have silently fallen back to the stale committed DTB anyway.

Pre-ASK builds got away with the same "stale committed DTB" pattern because nobody had yet added properties to the `.dts` that weren't present in the binary. The moment the `.dts` and `.dtb` desynced, the in-line build path no longer existed to mask it.

---

## 6. Fixes already shipped

| | Where | Effect |
|---|---|---|
| PR #31 | consumer `auto-build.yml` | Removed duplicate `workflow_call:` block; first green ASK release |
| `057855c` | consumer `bin/ci-pick-packages.sh` | ASK-aware kernel-presence check |
| `160b7c0` | consumer `bin/ci-build-iso.sh` | ASK-aware kernel-presence check (second pre-flight) |
| **PR #32** | consumer `data/dtb/mono-gw.dtb` | Recompiled (34046 B) from current DTS against ASK 6.6.135 — now *contains* the DWC3 quirks |
| **PR #32** | consumer `bin/ci-build-packages.sh` | Dropped `\|\| true` on `make freescale/mono-gateway-dk.dtb`, captured exit code, made FATAL when in-tree compile fails AND no SDK DTB is available |

---

## 7. Recommended follow-ups (not yet shipped)

1. Add a CI sanity step that `dtc -I dtb -O dts data/dtb/mono-gw.dtb \| diff -` against a freshly compiled DTB from the current `.dts` and fails if they diverge. Catches A independently of B.
2. Have the **producer** ship a built `mono-gw.dtb` as a release asset alongside the kernel `.deb`s, and make the consumer's `ci-consume-ask-kernel.sh` pull it. Single source of truth, no in-consumer DTB compilation needed.
3. Drop the committed `data/dtb/mono-gw.dtb` from the consumer entirely once (2) is in place.