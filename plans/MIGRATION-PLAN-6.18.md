# MIGRATION PLAN — Mainline Linux 6.18 Uplift

> **Status:** PLAN (not started). Owner: producer (`kernel-ls1046a-build`) + consumer (`vyos-ls1046a-build`).
> **Target:** retire `kernel-6.6.137-askN` (NXP `ask-6.6-port` base) and ship
> `kernel-6.18.26-ask1` from `kernel.org` mainline + our re-ported ASK overlay.
> **Trigger:** VyOS upstream `current` repo bumped `linux-image-*-vyos` to
> 6.18.26-vyos on 2026-05-06 22:29Z. Newest `jool`, `nat-rtsp`,
> `vyos-ipt-netflow`, `vyos-drivers-realtek-r8152` hard-depend on
> `linux-image-6.18.26-vyos`, breaking consumer's chroot install on 6.6.137.

## Strategic decisions (settled)

1. **Base = `kernel.org` mainline.** Not the NXP `ask-6.6-port` fork
   (dead branch) and not `lf-6.12.y` (still NXP-forked). Use exactly
   the URL VyOS rolling uses:
   `https://www.kernel.org/pub/linux/kernel/v6.x/linux-${ver}.tar.xz`
   with GPG verify against `torvalds@kernel.org` + `gregkh@kernel.org`.
2. **Initial target = `6.18.26`** (matches `vyos-build@HEAD/data/defaults.toml`).
   Drift forward with VyOS rolling thereafter (6.18.27, 6.19.x, etc.).
3. **Kept naming conventions:**
   - Producer repo: `kernel-ls1046a-build` (renamed 2026-05-07).
   - New release branch: `mainline-ls1046a` (or `main`; see Phase 0 Q3).
   - New tag scheme: `kernel-6.18.26-askN` (and `kernel-6.18.27-askN` etc.
     when we drift). The `askN` counter resets per upstream KVER.
   - LTS-fallback branch `lts-6.6-ls1046a` retained on the renamed repo
     for any future 6.6.137 hotfixes; no active development.
4. **NXP SDK driver overlay treatment.** The 266 files under
   `release/patches/kernel/sdk-sources/` (sdk_fman, sdk_dpaa, fsl_qbman,
   plus carry-overs) are kept as a one-time bootstrap from the working
   `nxp-qoriq/linux ask-6.6-port` source tree, then maintained in-tree
   under the existing `/* ASK-edit (askNN, mainline-6.18-port): rationale */`
   marker discipline (see `.clinerules/20-sdk-driver-rules.md`). Currently
   17 markers; expect the count to grow during phase 1 as 6.6→6.18 API
   drift surfaces.
5. **No re-introduction of mainline FMan/DPAA/QBMan.** The hard rules in
   `.clinerules/20-sdk-driver-rules.md` (use `FSL_SDK_*=y`, never
   `FSL_FMAN`/`FSL_DPAA_ETH`/mainline `drivers/soc/fsl/qbman/`) carry
   forward unchanged — this is what makes ASK userspace ABI keep working.

## Open design decisions (need resolution before phase 2)

| ID | Decision | Options | Default |
|---|---|---|---|
| D1 | Patch `040-xfrm-ipsec-offload` strategy | (a) Re-port full data-path additions to 6.18 net/xfrm/* surface. (b) Rewrite as a mainline `XFRM_OFFLOAD_*` provider hook + drop `CONFIG_INET_IPSEC_OFFLOAD`. | (b) — cleaner, avoids the 6.6.y compile breakage we already worked around |
| D2 | Patch `050-conntrack-offload` strategy | (a) Re-port `fp_info` additions to 6.18 `nf_conntrack_*`. (b) Delete the patch entirely and hook cdx into mainline `nftables flowtable` (which 6.18 has matured). | (b) — flowtable is now production-grade |
| D3 | Initial mainline target | (a) `6.18.26` (matches VyOS rolling today). (b) Latest 6.17.y stable. (c) Track 6.18-rcN until `.0` lands. | (a) |
| D4 | CI cost ceiling | Phase 1+2 will require ~10–15 ARM64 CI runs at ~22 min each (~5 hours). Capped or open? | Capped at 15 runs; if exceeded, pause and reassess |
| D5 | OOT module re-port order | `cdx` → `fci` → `auto_bridge`, or all-at-once big-bang? | `cdx` first (largest) — most API drift surfaces here |

These default to the (b/(a) options unless the user explicitly overrides.

## Phase 0 — Reconnaissance (no code changes)

**Goal:** capture the exact state of `vyos-build@HEAD` we'll be aligning to,
and produce a concrete diff against our current `release/patches/vyos/` +
`release/vyos-base/` so we know what's a real port vs. a no-op rebase.

Tasks:

- [ ] Snapshot `vyos-build@HEAD` reference artifacts into a non-tracked
      sandbox dir (e.g. `work/vyos-build-snapshot/`):
  - [ ] `data/defaults.toml`
  - [ ] `scripts/package-build/linux-kernel/build-kernel.sh` (canonical
        kernel-build flow we mirror)
  - [ ] `scripts/package-build/linux-kernel/patches/kernel/*.patch`
  - [ ] `config/arm64/vyos_defconfig`
  - [ ] `data/certificates/*.pem`
- [ ] Diff `release/patches/vyos/{001,002,003}-*.patch` against the snapshot's
      `patches/kernel/*.patch`:
  - [ ] `001-vyos-linkstate-ip-device-attribute.patch` — still needed?
        (mainline 6.18 may have absorbed `IFLA_LINK_STATE`).
  - [ ] `002-vyos-inotify-stackable-filesystems.patch` — still needed?
  - [ ] `003-vyos-build-linux-perf-package.patch` — VyOS may now ship
        their own packaging delta.
- [ ] Diff `release/vyos-base/arm64/vyos_defconfig` against snapshot's
      `config/arm64/vyos_defconfig`. Re-vendor ours from theirs (they are
      the source of truth) and re-apply the 7 fragment overlays
      (`{00-filesystems,01-executable-file-formats,02-module-signing,
      10-networking,11-encapsulation,11-wwan,20-netfilter}.config`).
- [ ] Diff `release/ask.config` against the merged 6.18 base — note any
      symbols that have moved/renamed (e.g. `CONFIG_NET_KEY` location).
- [ ] Audit `versions.lock` for assumptions about 6.6.y.

**Exit criteria:** a `plans/PHASE-0-FINDINGS.md` doc enumerating
- which `vyos/` patches are no-ops on 6.18 (delete),
- which need a re-port,
- the defconfig delta (added/removed/moved symbols),
- D1/D2/D3/D5 recommendation re-confirmed against actual 6.18 surface.

No commits. ETA: half a day of focused reading.

## Phase 1 — Kernel base + SDK overlay compiles on 6.18

**Goal:** `linux-6.18.26` extracts cleanly, the 266 SDK source files copy
into the tree via `scripts/apply-to-tree.sh`, and `make ARCH=arm64 vmlinux`
succeeds. No ASK fast-path patches yet; no OOT modules yet.

Tasks:

- [ ] Update `scripts/fetch-kernel.sh` to:
  - [ ] Accept `6.18.x` versions (regex currently pinned to `6\.6\.[0-9]+`).
  - [ ] Switch URL base to match VyOS flow:
        `https://www.kernel.org/pub/linux/kernel/v6.x/`.
  - [ ] Add GPG verify against `torvalds@kernel.org` + `gregkh@kernel.org`.
  - [ ] Update `versions.lock` writer to record kernel + signing key
        fingerprints.
- [ ] Add new branch `mainline-ls1046a` based on `lts-6.6-ls1046a`. Update
      `.github/workflows/build-and-release.yml` `branches:` trigger to
      include it. Tag pattern stays `kernel-*`.
- [ ] Re-vendor `release/vyos-base/arm64/vyos_defconfig` from
      `vyos-build@HEAD` (Phase-0 findings drive the selection).
- [ ] Audit each of the 7 fragment files for symbols that
      moved/renamed/disappeared in 6.18; bump.
- [ ] Re-confirm `release/ask.config` symbols are present in 6.18 Kconfig
      (`FSL_SDK_FMAN`, `FSL_SDK_DPAA_ETH`, `FSL_SDK_DPA`).
- [ ] Apply `release/patches/kernel/sdk-sources/` via existing
      `scripts/apply-to-tree.sh`. Catalog every compile error and resolve
      under marker discipline (`/* ASK-edit (ask1, mainline-6.18-port): … */`).
      Expect heavy churn here — 6.6 → 6.18 is two years of API drift,
      including: `class_create()` signature change, `genl_register_*` API,
      `tc_action_ops` changes, `phy_set_modulation()`, `xdp_buff` layout,
      MM page-table accessor changes, `folio` migration, etc.
- [ ] Re-validate the 6 patches under `release/patches/fixes/`:
  - [ ] `093-netlink-name-L2FLOW-cb-mutex.patch` — likely re-port (touches
        `net/netlink/genetlink.c`).
  - [ ] `094-swphy-10g-fixed-link.patch` — touches `drivers/net/phy/swphy.c`;
        may be obsolete in 6.18 (mainline picked up similar in 6.10+).
  - [ ] `095-leds-lp5812-register.patch` — likely still needed; trivial.
  - [ ] `097-ask-fci-nlkey-narrow-gate.patch` — re-port; `net/key/` API
        unchanged but defconfig logic re-validate.
  - [ ] `102-arm64-ioremap-cache-ns-shim.patch` — **still needed on 6.18**
        (mainline still does not define `ioremap_cache_ns` /
        `pgprot_cached_ns` / `PROT_NORMAL_NS` / `PTE_NS`); confirmed
        as recently as 6.18-rc.
  - [ ] `110-sdk-fman-dpaa-qbman-kasan-sanitize-off.patch` — still needed.
- [ ] `make ARCH=arm64 vmlinux Image dtbs modules` succeeds in CI.
- [ ] Cut throwaway tag `kernel-6.18.26-test1` to validate workflow path.
      Delete the tag + release after green build.

**Exit criteria:** clean `vmlinux` + `Image` build with the SDK overlay
linked in, no link errors, no modpost errors. ASK fast-path symbols are
not yet wired to any callers — that is phase 2.

## Phase 2 — Forward-port the 8 ASK fast-path patches

**Goal:** `release/patches/ask/{010..080}` apply cleanly on 6.18 and the
fast-path symbols / hooks compile + link. No userspace functional test yet.

Risk-ordered (lowest first; least likely to need conceptual rework):

- [ ] `080-wext-core-restore-ndo_do_ioctl.patch` — `net/wireless/wext-core.c`,
      trivial.
- [ ] `070-ppp-hooks.patch` — `drivers/net/ppp/*`, low risk.
- [ ] `060-netfilter-qosmark.patch` — pure additions
      (`net/netfilter/xt_QOSMARK.c`, etc.), low risk.
- [ ] `010-fman-dpaa-ehash.patch` — `drivers/net/ethernet/freescale/{Kconfig,Makefile}`
      + driver wiring; low risk after phase 1's heavy lift.
- [ ] `020-bridge-hooks.patch` — `net/bridge/*` + `include/linux/{if_bridge,skbuff}.h`;
      low–medium risk. `skbuff` layout in 6.18 has continued evolving
      (page-pool integration); may need hook offset relocation.
- [ ] `030-ipv4-ipv6-forwarding.patch` — `net/core/dev.c` + `net/ipv4/ip_output.c`
      + `net/ipv6/ip6_output.c`; **largest risk**, this is the deepest
      net-stack hook and 6.18 has restructured `__ip_local_out` and added
      BPF flow-dissector hooks.
- [ ] `040-xfrm-ipsec-offload.patch` — per **D1 default (b)**, rewrite
      as a mainline `XFRM_OFFLOAD_*` provider rather than re-porting the
      data-path additions. Drops `CONFIG_INET_IPSEC_OFFLOAD` (which we've
      had `=n` on 6.6 anyway), keeps `CONFIG_NET_KEY=y` for `cmm`'s
      `NETLINK_KEY=32` socket.
- [ ] `050-conntrack-offload.patch` — per **D2 default (b)**, **delete**
      this patch entirely. cdx hooks will move to mainline
      `nftables flowtable` for hardware offload. This is a behaviour
      change for the consumer's userspace (`fci` rules → `nft`-flavored
      rules), called out separately to the consumer-side plan.

**Exit criteria:** all 8 patches (or 7 + a flowtable substitution)
re-applied with `Pass: ≥17 Fail: 0` against `linux-6.18.26`. No new
modpost errors when the OOT modules are NOT loaded. `vmlinux` size is
within ±5% of the 6.6.137-ask42 baseline.

## Phase 3 — OOT modules + userspace patches re-port

**Goal:** `cdx.ko`, `fci.ko`, `auto_bridge.ko` build against the
phase-1+2 kernel; iptables-extensions still compile against 6.18 `xtables`
ABI; ppp/rp-pppoe userspace patches still apply.

Per **D5 default**, order is `cdx` → `fci` → `auto_bridge`.

Tasks:

- [ ] `release/oot-modules/cdx/` — expect compile errors against 6.18
      kernel headers. Apply marker-comment direct edits per
      `.clinerules/20-sdk-driver-rules.md`. Hot spots:
  - [ ] `cdx_main.c` module init / class API (6.18: `class_create()` signature).
  - [ ] `cdx_dev.c` cdev / file_operations / `kfifo` API.
  - [ ] `cdx_ehash.c` against re-ported `fm_ehash.c` (which lives in
        the SDK overlay and got its own ASK-edits in ask41/ask44).
  - [ ] `cdx_dpa_ipsec.c` — if D1 chose option (b), this needs to call
        `xfrm_state_register_offload()` instead of the legacy hooks.
- [ ] `release/oot-modules/fci/` — similar drift; `fci.c` registers
      a netlink family.
- [ ] `release/oot-modules/auto_bridge/` — bridge hook signature is
      tied to `020-bridge-hooks.patch`'s offsets.
- [ ] `release/oot-modules/iptables-extensions/` — `xtables` ABI in
      `iptables 1.8.10` (Debian Trixie ships) — verify ours still link.
- [ ] `release/userspace-patches/ppp/01-nxp-ask-ifindex.patch` — confirm
      against ppp 2.5.x (Trixie).
- [ ] `release/userspace-patches/rp-pppoe/01-nxp-ask-cmm-relay.patch` —
      same.

**Exit criteria:** `scripts/build-ask-modules.sh` produces all three
`.ko` files; `scripts/build-ask-iptables.sh` produces 6 `.deb`s;
`scripts/build-ask-ppp.sh` produces 3 `.deb`s. Module signing succeeds.

## Phase 4 — Producer release `kernel-6.18.26-ask1`

**Goal:** first published mainline-6.18 producer release.

Tasks:

- [ ] Update `release/manifest.json`:
  - [ ] Drop `nxp_sdk_repo` / `nxp_sdk_branch` / `nxp_sdk_sha` keys
        (stale labels — we're no longer mirroring NXP).
  - [ ] Add `kernel_upstream`: `https://www.kernel.org/pub/linux/kernel/v6.x/`.
  - [ ] Add `kernel_signing_keys`: `[torvalds@kernel.org, gregkh@kernel.org]`.
  - [ ] Bump `kernel_version` → `6.18.26`, `ask_iteration` → `ask1`.
  - [ ] Add `vyos_build_ref` recording the snapshot SHA used in phase 0.
- [ ] Update `.clinerules/00-tag-discipline.md` `Pre-tag gate` thresholds
      (Pass count, file count) to reflect phase-1+2 outcomes.
- [ ] Update `.clinerules/30-kconfig-defconfig.md` Sources of Truth
      table for any moved symbols.
- [ ] Update `.clinerules/50-thresholds-are-authoritative.md` invariants.
- [ ] Push tag `kernel-6.18.26-ask1` (TAG ONLY, no branch ref in same
      push — see `.clinerules/00-tag-discipline.md`).

**Exit criteria:** GitHub Release `kernel-6.18.26-ask1` exists with
the standard 9 assets; `gh release view` returns clean.

## Phase 5 — Consumer hardware boot test

**Goal:** consumer (`vyos-ls1046a-build`) builds and boots a VyOS image
against `kernel-6.18.26-ask1` on real Mono Gateway hardware.

(Consumer-side plan — full detail in `vyos-ls1046a-build/plans/MIGRATION-PLAN-6.18.md`.)

Producer-visible touchpoints:

- [ ] Consumer pin: bump `data/ask-kernel.pin` from
      `kernel-6.6.137-ask42` to `kernel-6.18.26-ask1`.
- [ ] Consumer's `bin/ci-setup-vyos-build.sh` self-pinning logic
      (rewrites `vyos-build/data/defaults.toml.kernel_version`) reads the
      ASK kernel deb's filename — confirm that still parses for `6.18.26-vyos`.
- [ ] Consumer's apt pin
      `vyos-build/data/live-build-config/archives/00-pin-ask-kernel.pref.chroot`
      keeps blocking `linux-image-*-vyos` from `packages.vyos.net` (no
      change needed — pattern matches both 6.6.137-vyos and 6.18.26-vyos).
- [ ] On-target boot: `ask-check` Chain 1 + Chain 2 both green
      (see `.clinerules/05-workspace-layout.md` two-chain failure model).
- [ ] If Chain 2 sub-trigger A (MURAM exhaustion) or B (NULL-deref in
      `copy_td_to_ccbase`) re-emerges, the producer-side ask41 / ask39
      direct edits in the SDK source tree carry forward verbatim into the
      mainline-6.18 base — the EHASH / `copy_td_to_ccbase` code paths are
      in the SDK overlay, not in mainline.

**Exit criteria:** all 5 ports working (eth0..eth4); `dpa_app applied
PCD configuration` succeeds; `cmm.service active`; throughput within
±5% of 6.6.137-ask42 baseline.

## What the tag scheme will look like after this

```
kernel-6.6.137-ask42        (last 6.6 LTS release, on lts-6.6-ls1046a branch)
  ↓ (no further iterations expected; branch is fallback only)

kernel-6.18.26-ask1         (first mainline release, on mainline-ls1046a branch)
kernel-6.18.26-ask2..N      (iterations until consumer hardware boot is green)
kernel-6.18.27-ask1         (when VyOS rolling drifts forward; askN resets)
kernel-6.19.x-ask1          (etc.)
```

## What we are NOT doing (explicit non-goals)

1. We are **not** going through `lf-6.12.y` as a stepping stone —
   that's still NXP-forked and would just defer this same migration.
2. We are **not** continuing to maintain `ask-6.6-port` on the producer
   beyond `ask42`. The `lts-6.6-ls1046a` branch is fallback-only.
3. We are **not** introducing a parallel quilt-style patch stack on top
   of the SDK source tree — direct-edit policy with `ASK-edit` markers
   is the only mechanism (per `.clinerules/20-sdk-driver-rules.md`).
4. We are **not** switching to mainline FMan/DPAA/QBMan — see
   `.clinerules/20-sdk-driver-rules.md`. Userspace ABI breakage is
   not acceptable.
5. We are **not** attempting a 6.18 build before phase 0 reconnaissance.
   Premature compile attempts waste ~22 min ARM64 CI minutes per shot
   and don't produce signal we can't get from local diff'ing of
   `vyos-build@HEAD`.

## Companion plan

Consumer-side (`vyos-ls1046a-build`) has its own `plans/MIGRATION-PLAN-6.18.md`
covering: VyOS rolling drift handling, `ask-kernel.pin` rev, OOT module
package-naming sync, hardware test plan, rollback procedure.