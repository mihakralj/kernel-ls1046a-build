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

Must report `Pass: 13   Fail: 0` and `0 SDK conflicts (264 files to install)`. A clean `patch-health` is **not sufficient** — `git apply` may report success even when a patch's hunk count is wrong and lines get silently truncated. After patch-health, also visually inspect the affected file:

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

SDK source files (264 of them) are dropped under `release/patches/kernel/sdk-sources/` and copied into the kernel tree by `scripts/apply-to-tree.sh`.

## Driver Stack (the why behind ASK)

ASK ships **NXP SDK drivers**, not mainline:

| Symbol | Path | Mainline equivalent (NOT used) |
|---|---|---|
| `CONFIG_FSL_SDK_FMAN=y` | `drivers/net/ethernet/freescale/sdk_fman/` | `fman/` (`CONFIG_FSL_FMAN`) |
| `CONFIG_FSL_SDK_DPAA_ETH=y` | `drivers/net/ethernet/freescale/sdk_dpaa/` (fsl_mac, fsl_dpa) | `dpaa/` (`CONFIG_FSL_DPAA_ETH`) |
| `CONFIG_FSL_SDK_DPA=y` | `drivers/staging/fsl_qbman/` | `drivers/soc/fsl/qbman/` |

The SDK is required because mainline doesn't expose USDPAA / FMC / `dpa_ipsec` / `fmlib` userspace ABI consumed by the ASK userspace tools (`dpa_app`, `fmc`, etc).

Known SDK pitfall: `sdk_dpaa/mac.c:202` returns `-ENODEV` (not `-EPROBE_DEFER`) when `fm_bind()` finds FMan not yet probed. Mainline doesn't have this — it uses the component framework. Init order between `sdk_fman/` and `sdk_dpaa/` therefore matters; patch `ask/010`'s Makefile orders `sdk_fman/` first.

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