# reference/ — read-only ASK references

This directory contains read-only snapshots of upstream ASK source trees,
vendored in-tree to satisfy the producer's "self-contained build" rule
(see `.clinerules/05-workspace-layout.md`).

**Read-only**. No build script consumes these paths. They exist for:

1. **Cribsheet** during patch refresh — how did upstream re-shape ASK
   hooks for the 6.6 → 6.12 transition? Half of the 6.6 → 6.18 API drift
   is already resolved in `ASK-mt-6.12.y/patches/kernel/`.
2. **Source for OOT lifts** when a symbol is genuinely out-of-mainline
   (NXP-private API helpers, SDK header types). Lifted code lands under
   our `/* ASK-edit (...) */` marker discipline in `release/`.
3. **Provenance** for any code we adopt from these branches.

## Snapshots

| Path | Source | SHA | Date | Branch | Size |
|---|---|---|---|---|---|
| `ASK-mt-6.12.y/` | `https://github.com/we-are-mono/ASK` | `a211ea865379362058c6656b9c448e4a7050e93c` | 2026-05-07 | `mt-6.12.y` | 5.1 MB / 279 files |
| `ASK-fix-security-hardening/` | `https://github.com/we-are-mono/ASK` | `422e184ff68a8176682943de47e1d7436b19245f` | 2026-05-07 | `fix/security-hardening` | 6.4 MB |
| `vyos-build/` | `https://github.com/vyos/vyos-build` | `2413b09291341031d77066db5f84509a7def54cd` | 2026-05-07 | `current` | 508 KB / 40 files (selective subset) |

Each snapshot was produced via:
```sh
git clone --depth 1 --branch <BRANCH> --single-branch \
    https://github.com/we-are-mono/ASK <REF>
rm -rf <REF>/.git <REF>/build
```

## What's inside (mt-6.12.y)

The upstream `we-are-mono/ASK` repo has the **same structure as our `release/`**:

| Upstream path | Maps to our `release/` path |
|---|---|
| `cdx/`, `fci/`, `auto_bridge/` | `release/oot-modules/{cdx,fci,auto_bridge}/` |
| `iptables-extensions/` | `release/oot-modules/iptables-extensions/` |
| `patches/kernel/002-mono-gateway-ask-kernel_linux_6_12.patch` | consolidates → `release/patches/{ask,fixes}/*.patch` |
| `patches/kernel/999-layerscape-ask-kernel_linux_5_4_3_00_0.patch` | source bundle → `release/patches/kernel/sdk-sources/` |
| `patches/{ppp,rp-pppoe,libnetfilter-conntrack,libnfnetlink}/` | `release/userspace-patches/{ppp,rp-pppoe}/` + ask-userspace tree |
| `patches/{fmlib,fmc}/` | `vyos-ls1046a-build/ask-userspace/{fmlib,fmc}/` |
| `cmm/`, `dpa_app/` | `vyos-ls1046a-build/ASK/{cmm,dpa_app}/` |
| `config/` | `release/vyos-base/` + `release/ask.config` (different shape) |

The headline asset for our 6.18 port is:

- `ASK-mt-6.12.y/patches/kernel/002-mono-gateway-ask-kernel_linux_6_12.patch`
  — 17,900 lines, 138 files. The complete `we-are-mono` ASK delta
  against linux 6.12.49. This is the **6.6 → 6.12 cribsheet** for our
  Phase-2 patch re-port work.

## What's inside (vyos-build)

Selective subset of the `current` branch (rolling), capturing only the
artefacts our migration plan needs to align against:

| Path | Purpose |
|---|---|
| `data/defaults.toml` | Source of truth for `kernel_version`, `kernel_flavor`, debian_distribution. Currently `kernel_version = "6.18.26"`, `debian_distribution = "bookworm"` (note: still bookworm in defaults.toml even though VyOS rolling builds on trixie in CI). |
| `data/certificates/vyos-prod-2025-linux.pem` | Trusted-keys cert embedded in `linux-image-*-vyos`. Our consumer-side ISO must trust this cert too. |
| `scripts/package-build/linux-kernel/build-kernel.sh` | Canonical kernel-build flow we mirror in `scripts/build-kernel.sh`. |
| `scripts/package-build/linux-kernel/patches/kernel/*.patch` | The **2** kernel patches VyOS rolling carries: `0001-linkstate-ip-device-attribute.patch`, `0003-build-linux-perf-package.patch`. (Their old `0002-inotify-stackable-filesystems` was dropped.) |
| `scripts/package-build/linux-kernel/config/arm64/vyos_defconfig` | 5,797-line ARM64 base defconfig. Source of truth — we re-vendor from this. |
| `scripts/package-build/linux-kernel/config/*.config` | 21 kconfig fragments (was 7 in our older snapshot). Notable additions: `13-net-sched`, `14-mpls`, `15-wireless`, `30-pwru`, `40-crypto`, plus 11 separated net-encap fragments. |
| `scripts/package-build/linux-kernel/patches/{intel-qat,ipt-netflow,ixgbe}/` | OOT driver patches (irrelevant to LS1046A; vendored for completeness). |

## Update procedure

These snapshots are versioned in this repo. To bump:

1. Re-run the `git clone --depth 1 --branch <BRANCH>` command above.
2. Replace the old `<REF>/` directory with the new contents.
3. Update the SHA + date in this file.
4. Commit as `chore(reference): bump <BRANCH> to <SHA-prefix>`.
5. Note in the commit body any items that materially changed (especially
   if `patches/kernel/002-mono-gateway-ask-kernel_linux_6_12.patch`
   changed — that's our cribsheet).
