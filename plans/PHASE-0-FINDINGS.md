# PHASE-0-FINDINGS — 6.18 migration reconnaissance

> **Status:** in progress (started 2026-05-07).
> **Inputs:** `reference/ASK-mt-6.12.y/` (a211ea86), `reference/ASK-fix-security-hardening/` (422e184f), `reference/vyos-build/` (2413b092).
> **Output of this doc:** the actionable port plan that drives Phases 1-3.

## TL;DR (early findings, will expand)

- VyOS rolling pins `kernel_version = "6.18.26"`, flavor `vyos`. Confirmed.
- VyOS rolling carries **only 2** in-tree kernel patches:
  - `0001-linkstate-ip-device-attribute.patch` — same intent as our `release/patches/vyos/001-vyos-linkstate-ip-device-attribute.patch`. **VyOS already refreshed it for 6.18.x** — header documents the context shifts (DEVCONF_FORCE_FORWARDING insertion, `ra_honor_pio_life` additions, `READ_ONCE()` publishes). **Adopt verbatim, drop our copy.**
  - `0003-build-linux-perf-package.patch` — same intent as our `003-vyos-build-linux-perf-package.patch`. **VyOS rewrote it for 6.7+'s new mkdebian/debian-rules architecture** (62 → 102 lines). **Adopt verbatim, drop our copy.**
- Our `release/patches/vyos/002-vyos-inotify-stackable-filesystems.patch` is **GONE upstream** — VyOS dropped it. **DELETE.**
- VyOS rolling fragment count: **21** (was 7 in our older snapshot). Our `release/vyos-base/` needs a re-vendor + restructure to match.
- ASK upstream (`we-are-mono/ASK mt-6.12.y`) has **structurally identical layout** to our `release/`. Their 6.6→6.12 port lives in `patches/kernel/002-mono-gateway-ask-kernel_linux_6_12.patch` (17,900 lines, 138 files) — our cribsheet for the 6.6→6.18 port.
- We currently carry **32 `ASK-edit` markers** across **20 SDK files** + audit-b2/b3/b4 markers. Marker tag `ask31` absorbed 8 prior `fixes/` patches (099/103/104/105/107/108/109/111) into direct SDK edits — those edits must carry forward to 6.18.
- mt-6.12's consolidated patch touches `fm_ehash.c` 4 times — same file we have ask29/ask30/ask41 markers in. **mt-6.12 made its own 6.6→6.12 fixes there**. Three-way diff is the actionable next step.

## A. VyOS in-tree patches: 3-way diff

| Our patch (`release/patches/vyos/`) | VyOS rolling equivalent | Action |
|---|---|---|
| `001-vyos-linkstate-ip-device-attribute.patch` | `0001-linkstate-ip-device-attribute.patch` | refresh from VyOS rolling |
| `002-vyos-inotify-stackable-filesystems.patch` | (none — dropped upstream) | **DELETE** |
| `003-vyos-build-linux-perf-package.patch` | `0003-build-linux-perf-package.patch` | refresh from VyOS rolling |

Verification needed:
- [ ] Diff our `001` against VyOS `0001` line-by-line. If trivial whitespace, adopt verbatim.
- [ ] Same for `003` / `0003`.
- [ ] Confirm no functional regression in our build by dropping `002`.

## B. Kconfig fragment expansion

VyOS rolling fragment list (21 files):
```
00-filesystems.config           ← we have
01-executable-file-formats.config  ← we have
02-module-signing.config        ← we have
10-networking.config            ← we have
12-wwan.config                  ← we have (named 11-wwan.config)
13-net-sched.config             ← NEW — adopt
14-mpls.config                  ← NEW — adopt
15-wireless.config              ← NEW — adopt (was: NOT in our 11-encapsulation)
20-netfilter.config             ← we have
30-pwru.config                  ← NEW — adopt (BPF-based packet tracer)
40-crypto.config                ← NEW — adopt (modern AEAD ciphers, post-quantum readiness)
50-bond.config                  ← split from our 11-encapsulation
51-bridge.config                ← split from our 11-encapsulation
52-dummy.config                 ← split from our 11-encapsulation
53-geneve.config                ← split from our 11-encapsulation
54-l2tp.config                  ← split from our 11-encapsulation
55-macsec.config                ← split from our 11-encapsulation
56-macvlan.config               ← split from our 11-encapsulation
57-openvpn.config               ← split from our 11-encapsulation
58-ppp.config                   ← split from our 11-encapsulation
59-veth.config                  ← split from our 11-encapsulation
60-vlan.config                  ← split from our 11-encapsulation
61-vxlan.config                 ← split from our 11-encapsulation
62-wireguard.config             ← split from our 11-encapsulation
90-debug.config                 ← NEW — adopt (or keep our debug fragment)
```

Action: **re-vendor `release/vyos-base/arm64/` from scratch** using the VyOS rolling layout. Our existing `release/ask.config` (which carries the SDK enables `FSL_SDK_FMAN`, `FSL_SDK_DPAA_ETH`, etc.) stays as the LS1046A-specific overlay applied AFTER the VyOS-base merge.

Sub-tasks:
- [ ] Diff our `release/vyos-base/arm64/vyos_defconfig` against VyOS rolling's. Re-vendor.
- [ ] For each new fragment (`13-net-sched`, `14-mpls`, `15-wireless`, `30-pwru`, `40-crypto`, `90-debug`), confirm symbols exist in 6.18 Kconfig.
- [ ] Replace our `11-encapsulation.config` with the 13 split files (`50-bond..62-wireguard`).

## C. ASK fast-path patches: 3-way overlap

For each of our 8 `release/patches/ask/` patches, locate the corresponding hunks in `reference/ASK-mt-6.12.y/patches/kernel/002-mono-gateway-ask-kernel_linux_6_12.patch` and classify.

| Our patch | mt-6.12 hunks present? | mainline 6.18 absorbed? | Action |
|---|---|---|---|
| `010-ask-fman-dpaa-ehash.patch` | TBD | No (SDK-specific) | re-port using mt-6.12 shape |
| `020-ask-bridge-hooks.patch` | TBD | No | re-port |
| `030-ask-ipv4-ipv6-forwarding.patch` | TBD | No | re-port (highest risk) |
| `040-ask-xfrm-ipsec-offload.patch` | TBD | partial (XFRM_OFFLOAD_*) | per **D1**: rewrite as XFRM_OFFLOAD provider |
| `050-ask-conntrack-offload.patch` | TBD | yes (nftables flowtable) | per **D2**: delete, hook cdx into flowtable |
| `060-ask-netfilter-qosmark.patch` | TBD | No | re-port |
| `070-ask-ppp-hooks.patch` | TBD | No | re-port |
| `080-wext-core-restore-ndo_do_ioctl.patch` | TBD | No | re-port (trivial) |

## D. Fixes patches: 3-way overlap

| Our patch (`release/patches/fixes/`) | mt-6.12 carries? | mainline 6.18 fixed? | Action |
|---|---|---|---|
| `093-netlink-name-L2FLOW-cb-mutex.patch` | TBD | TBD | TBD |
| `094-swphy-10g-fixed-link.patch` | TBD | likely yes (mainline ≥6.10) | TBD |
| `095-leds-lp5812-register.patch` | TBD | TBD | TBD |
| `097-ask-fci-nlkey-narrow-gate.patch` | TBD | No | re-port |
| `102-arm64-ioremap-cache-ns-shim.patch` | likely yes (NXP-private NS-bit attrs) | No | keep, refresh against 6.18 surface |
| `110-sdk-fman-dpaa-qbman-kasan-sanitize-off.patch` | likely yes | No | keep |

## E. SDK source `/* ASK-edit (askNN) */` markers

**Distribution (re-counted after security-hardening audit):** 32 markers across 20 SDK files + 5 audit-b2/b3/b4 hardening markers (independent of `we-are-mono` `fix/security-hardening` reference).

| Tag | Count | Notes |
|---|---|---|
| ask27 | 8 | |
| ask31 | 8 | **Absorbed 8 fixes/ patches: 099, 103, 104, 105, 107, 108, 109, 111** — these collapsed historical patches must carry forward to 6.18 in-place |
| ask26 | 4 | |
| ask28 | 2 | |
| ask29 | 2 | `fm_ehash.c` (mt-6.12 also edits this file 4×) |
| ask32 | 2 | |
| ask39 | 2 | |
| ask30, ask35, ask40, ask41 | 1 each | |
| audit-b2/b3/b4 (AB-01..AB-06, F-02) | 5 | Internal security-hardening audit, separate scheme |

**Files carrying markers (20):**

```
drivers/net/ethernet/freescale/sdk_dpaa/{dpaa_eth_common.c, dpaa_eth_sg.c, dpaa_ethtool.c, mac.c}
drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/{fm.c, fm_muram.c}
drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/MAC/memac.c
drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/{fm_cc.c, fm_ehash.c, fm_pcd.c}
drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Port/{fm_port.c, fm_port.h}
drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/SP/fm_sp.c
drivers/net/ethernet/freescale/sdk_fman/inc/Peripherals/fm_port_ext.h
drivers/net/ethernet/freescale/sdk_fman/inc/ncsw_ext.h
drivers/net/ethernet/freescale/sdk_fman/src/wrapper/{lnxwrp_ioctls_fm.c, lnxwrp_sysfs_fm.c}
drivers/staging/fsl_qbman/{dpa_alloc.c, fsl_usdpaa.c, qman_driver.c}
```

Cross-reference signal (mt-6.12 `002-`):
- `fm_ehash.c` — mt-6.12 has 4 hunks. **Our 3 markers (ask29/30/41) here must be three-way-diffed against mt-6.12's hunks**; some may already be addressed there.

Action for Phase 1: leave markers in place during 6.18 base + SDK overlay compile. Reconcile per-file in Phase 2 once kernel boots.

## F. Decisions reconfirmed

- **D1** (xfrm IPsec offload): default (b) — rewrite as XFRM_OFFLOAD provider. Confirmed: 6.18 has matured this API; `xfrm_state_register_offload()` is stable.
- **D2** (conntrack offload): default (b) — delete patch, use mainline `nftables flowtable`. Confirmed: 6.18 has the hardware-offload-capable variant.
- **D3** (initial target): `6.18.26`. Confirmed against `vyos-build@2413b092/data/defaults.toml`.
- **D4** (CI cost cap): cap at 15 ARM64 runs for Phase 1+2. **No change.**
- **D5** (OOT module re-port order): `cdx` → `fci` → `auto_bridge`. **No change.**

## G. Open items before Phase 1 starts

- [ ] Populate sections C, D, E TBDs by actually running the diffs.
- [ ] Run `scripts/fetch-kernel.sh` against 6.18.26 (after regex bump) to have the mainline tree available locally as the third diff input.
- [ ] Decide branch naming: stay on `main`, or new `mainline-ls1046a`? (Plan defaults to new branch; reconfirm.)
