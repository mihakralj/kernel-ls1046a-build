# lts_6.6_ls1046a

> Producer of the **ASK kernel** for NXP LS1046A boards: Linux 6.6.135 LTS + VyOS deltas + NXP SDK DPAA / FMan / QBMan drivers + ASK fast-path hooks. Publishes per-tag GitHub Releases that the consumer [`vyos-ls1046a-build`](https://github.com/mihakralj/vyos-ls1046a-build) pins against.

ASK ([Application Solutions Kit](https://github.com/we-are-mono/ASK)) is NXP/Mono's fast-path networking stack: SDK FMan/DPAA/QBMan drivers, netfilter offload hooks, IPsec crypto-engine plumbing, conntrack/QoS extensions. It targets whichever kernel Mono is building against — currently **6.12**. VyOS 1.5/1.6 (and everything else that pins a 6.6 LTS kernel) is five years behind that.

This repo is the bridge: a hand-curated, bucketed patch set that ports ASK forward to **kernel.org 6.6.135 LTS**, plus the verbatim SDK driver source drops the patches need, plus a CI workflow that builds it natively on `ubuntu-24.04-arm` (~22 min) and ships `.deb` files as a tagged GitHub Release.

The current released kernel is **`kernel-6.6.135-ask50`**.

---

## Repo layout (source of truth)

```text
lts_6.6_ls1046a/
├── release/                              # what the kernel build consumes
│   ├── patches/
│   │   ├── vyos/    (3 patches)          # VyOS deltas, applied first
│   │   ├── ask/     (8 patches)          # ASK fast-path hooks
│   │   ├── fixes/   (4 patches)          # 6.6.y-specific repairs
│   │   └── kernel/sdk-sources/  (266 files)  # verbatim NXP SDK drivers
│   ├── vyos-base/                        # VyOS defconfig fragments
│   │   ├── arm64/vyos_defconfig
│   │   └── *.config                      # filesystems / networking / netfilter / ...
│   ├── ask.config                        # LS1046A/DPAA delta (wins last)
│   └── manifest.json                     # provenance pointers
├── scripts/                              # build pipeline
├── .github/workflows/                    # CI (native ARM64 build + release on tag)
├── .clinerules/                          # agent rules
├── .clineskills/                         # agent skills
├── .clinehooks/                          # agent hooks (block-dual-ref-push, hunk-validator)
├── AGENTS.md                             # agent documentation, two-chain failure model
└── work/                                 # gitignored — build scratch + caches
```

The patch set applies in fixed order: `vyos/` → `ask/` → `fixes/`. Within each bucket, sort by filename prefix. SDK source files under `release/patches/kernel/sdk-sources/` are dropped verbatim into the kernel tree by `scripts/apply-to-tree.sh` — they are NOT patches.

### Patch inventory

| Bucket | # | Name | Purpose |
|---|---|---|---|
| `vyos/` | 001 | `vyos-linkstate-ip-device-attribute.patch` | VyOS link-state IFLA attr |
| `vyos/` | 002 | `vyos-inotify-stackable-filesystems.patch` | inotify on overlayfs |
| `vyos/` | 003 | `vyos-build-linux-perf-package.patch` | linux-perf .deb |
| `ask/`  | 010 | `ask-fman-dpaa-ehash.patch` | FMan/DPAA misc + SDK Kconfig+Makefile wiring |
| `ask/`  | 020 | `ask-bridge-hooks.patch` | Bridge fast-path hooks (`abm_ff`, brevent notifier) |
| `ask/`  | 030 | `ask-ipv4-ipv6-forwarding.patch` | IPv4/IPv6 forwarding fast-path |
| `ask/`  | 040 | `ask-xfrm-ipsec-offload.patch` | IPsec offload (gated by `INET_IPSEC_OFFLOAD`, **=n on 6.6**) |
| `ask/`  | 050 | `ask-conntrack-offload.patch` | Conntrack offload (`fp_info`, `qosconnmark`) |
| `ask/`  | 060 | `ask-netfilter-qosmark.patch` | `comcerto_fp_netfilter.c` + xt_QOSMARK/QOSCONNMARK |
| `ask/`  | 070 | `ask-ppp-hooks.patch` | PPP fast-path hooks |
| `ask/`  | 080 | `wext-core-restore-ndo_do_ioctl.patch` | Wireless-extensions core restore |
| `fixes/` | 093 | `netlink-name-L2FLOW-cb-mutex.patch` | Lockdep mutex name (avoid dup vs NETLINK_GENERIC) |
| `fixes/` | 094 | `swphy-10g-fixed-link.patch` | 10G fixed-link swphy support |
| `fixes/` | 095 | `leds-lp5812-register.patch` | Register lp5812 LED driver in `drivers/leds/Makefile`+`Kconfig` |
| `fixes/` | 097 | `ask-fci-nlkey-narrow-gate.patch` | `net/key/ask_fci_nlkey.c` + `CONFIG_ASK_FCI_NLKEY` to register `NETLINK_KEY=32` without enabling the (broken-on-6.6) IPsec offload data path |

---

## Producer invariants (load-bearing)

`scripts/patch-health.sh --source release` must report exactly:

```text
Pass: 15   Fail: 0
0 SDK conflicts (266 files to install)
```

These numbers are **producer-contract invariants**, not knobs. Lowering an assertion to make a failing build pass is forbidden (see `.clinerules/50-thresholds-are-authoritative.md`).

A clean `patch-health` is **necessary but not sufficient**: `git apply` may report success while a malformed `@@` hunk header silently truncates added lines. After every patch edit, also visually inspect the affected file — see the procedure in `.clinerules/10-patch-authoring.md`.

### Reference-aligned defconfig invariants

| Symbol | Reference (NXP/ASK 6.12) | This repo on 6.6 | Why |
|---|---|---|---|
| `CONFIG_NET_KEY` | `=y` | `=y` | Required so `obj-y` items in `net/key/Makefile` (patch 097) are honored. |
| `CONFIG_INET_IPSEC_OFFLOAD` | `=y` | **`=n`** | Reference path needs `xfrm_state` fields (`curr_time`, `offloaded`) that don't exist on 6.6.y. Re-enabling fails to compile. |
| `CONFIG_CPE_FAST_PATH` | `=y` | `=y` | ASK fast-path master gate. |
| `CONFIG_ASK_FCI_NLKEY` | n/a | `=y` | 6.6 narrow-gate; registers proto 32 without pulling in the IPsec offload data path. |

ASK on 6.6 deliberately does **not** enable `INET_IPSEC_OFFLOAD`; the IPsec offload data path is structurally incompatible with mainline 6.6 `xfrm_state`. The `ASK_FCI_NLKEY` narrow gate (patch 097 + the `=y` defconfig line) is the supported path forward — it provides only what `cmm`'s `fci_open()` requires.

---

## Build pipeline (the seven scripts that matter)

| Script | Purpose |
|---|---|
| `scripts/patch-health.sh --source release` | Validate the patch set against pristine `linux-6.6.135`. Runs in seconds. |
| `scripts/apply-to-tree.sh` | Apply patches AND copy verbatim SDK source drops into the kernel tree. Owns the 266-file invariant. |
| `scripts/build-kernel.sh` | Native ARM64 kernel build → `work/build/*.deb`. |
| `scripts/build-ask-modules.sh` | Out-of-tree ASK modules (cdx / fci / auto_bridge) → `ask-modules-*_arm64.deb`. Skipped when FMan SDK absent. |
| `scripts/build-ask-iptables.sh` | Patched `iptables` source rebuild + `xt_QOSMARK` / `xt_QOSCONNMARK` extensions. |
| `scripts/build-ask-ppp.sh` | Patched `ppp` (NXP ifindex fix) + `rp-pppoe` (CMM relay; needs ASK userspace). |
| `scripts/run-pipeline.sh` | Linearises the lot. |
| `scripts/publish-binaries.sh` | Ship to GitHub Release. |
| `scripts/publish-release.sh` | Promote `work/derived/` → `release/` (legacy reconciliation flow). |
| `scripts/normalize-patch.awk` | Pipe `git diff --no-prefix` through this when authoring patches. Repairs zero-prefix context lines so `git apply --check` accepts them strictly. |
| `scripts/diff-vyos-config.sh` | Compare VyOS defconfig fragments vs an upstream reference. Useful when defconfig changes — surface the diff in the commit body. |

CI: `.github/workflows/build-and-release.yml` runs natively on `ubuntu-24.04-arm`. **Tag pushes** to `kernel-*` publish a Release; **branch pushes** are safety-net builds only. ARM64 minutes are not free at scale — do not push branch + tag in the same `git push`. See `.clinerules/00-tag-discipline.md`.

---

## Cutting an ASK release iteration

Standard flow for a new `kernel-6.6.135-askN`:

```bash
# 1. Author / edit a patch
( cd work/linux-6.6.135 && git diff --no-prefix ) \
  | awk -f scripts/normalize-patch.awk \
  > release/patches/<bucket>/0XX-name.patch

# 2. Re-extract pristine tree, validate
rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/
bash scripts/patch-health.sh --source release
#   Required: Pass: 15   Fail: 0   0 SDK conflicts   266 files

# 3. Visually verify the affected file
patch -p1 -d work/linux-6.6.135 < release/patches/<bucket>/0XX-name.patch
grep -n <expected-content> work/linux-6.6.135/<patched-file>

# 4. Commit (one logical change per commit; prefix per .clinerules/40)
git commit -am 'ask: …'    # or vyos: / fixes: / sdk: / scripts: / ci: / docs:

# 5. Tag and TAG-ONLY push
git tag kernel-6.6.135-askN
git push origin kernel-6.6.135-askN     # ← do NOT also push the branch ref
```

The `.clinehooks/block-dual-ref-push.sh` pre-push hook will refuse a push that combines a branch ref with a `kernel-*` tag. Engage it via `git config core.hooksPath .clinehooks` if not already configured.

---

## Failure-routing reference (post-ask49)

`ask-check` failures on the consumer collapse into **two independent chains**. Knowing which chain a symptom belongs to is critical for routing the fix:

| Chain | Symptoms | Trigger | Fix repo |
|---|---|---|---|
| **1 — kernel-side** | `cmm process running [FAILED]`, `cmm.service active [FAILED]` | `socket(AF_NETLINK, SOCK_RAW, NETLINK_KEY=32) = -EPROTONOSUPPORT` | **this repo** — patch 097 + `CONFIG_NET_KEY=y` (resolved in ask50) |
| **2 — userspace-side** | `dpa_app applied PCD configuration (failed rc=65280)`, `BMan fragment buffer pool located by CDX [FAILED]`, `no ASK driver probe/init/bind failures (≥1 hit(s))` | `fm_cc.c:4377 AllocStatsObjs Memory Allocation Failed` (FMan MURAM exhausted because `cdx_pcd.xml` requests ~16K stats objects + DDR offload attrs that on-target `fmc` silently drops) | **`vyos-ls1046a-build`** — rebuild `fmc`/`fmlib` from a tag that supports `external="yes" aging="yes"`, and/or trim `cdx_pcd.xml` |

The chains are independent. `fci.ko` does NOT register `NETLINK_KEY` (that is the in-tree `ask_fci_nlkey` `late_initcall`'s job). `dpa_app` runs from `cdx_module_init`, independent of `cmm`. Diagnose each chain separately and route fixes to the correct repo.

Full diagnostic checklists per chain live in [`AGENTS.md`](./AGENTS.md#two-chain-failure-model-post-ask49).

---

## Consumer integration

`vyos-ls1046a-build` pins this repo by tag. From its CI:

```bash
KERNEL_TAG="kernel-6.6.135-ask50"
gh release download -R mihakralj/lts_6.6_ls1046a "$KERNEL_TAG" \
  --pattern 'linux-*.deb' \
  --pattern 'ask-modules-*.deb' \
  --pattern 'iptables_*.deb' \
  --pattern 'libxtables*.deb' --pattern 'libip*tc*.deb' \
  --pattern 'ppp_*.deb' \
  --pattern 'SHA256SUMS' \
  --pattern 'manifest.json' \
  -D /tmp/ask-kernel/
(cd /tmp/ask-kernel && sha256sum -c SHA256SUMS)
```

The tag is immutable: byte-identical artefacts forever. The consumer's lockfile decides when to bump.

---

## Documentation map

| File | Purpose |
|---|---|
| `README.md` (this file) | Repo overview, patch inventory, current state. |
| [`AGENTS.md`](./AGENTS.md) | Agent rules: tag discipline, patch-health invariants, defconfig invariants, two-chain failure model. |
| [`FIXES.md`](./FIXES.md) | Historical SDK 5.15 → 6.6 import API-shim log (frozen; pre-bucketed era). |
| [`FIX-PLAN-ASK-PCD.md`](./FIX-PLAN-ASK-PCD.md) | Chain-2 diagnosis (PCD MURAM exhaustion). Routed to `vyos-ls1046a-build`. |
| [`FIX-PLAN-FCI-NETLINK-KEY.md`](./FIX-PLAN-FCI-NETLINK-KEY.md) | Chain-1 diagnosis history (resolved by ask50). |
| `.clinerules/00-tag-discipline.md` | Producer release workflow rules. |
| `.clinerules/10-patch-authoring.md` | Hunk-header arithmetic + verification loop. |
| `.clinerules/20-sdk-driver-rules.md` | NXP SDK driver invariants (the why behind ASK). |
| `.clinerules/30-kconfig-defconfig.md` | Kconfig & defconfig discipline. |
| `.clinerules/40-commit-style.md` | Commit / tag message style. |
| `.clinerules/50-thresholds-are-authoritative.md` | Numeric invariants (15 / 0 / 266). |
| `.clinerules/60-tooling-paths.md` | Canonical tooling paths. |

---

## License and provenance

GPL-2.0, matching both upstreams this work stands on:

- [`vyos/vyos-build`](https://github.com/vyos/vyos-build) (GPL-2.0)
- [`we-are-mono/ASK`](https://github.com/we-are-mono/ASK) (GPL-2.0)

Attribution:

- **NXP** authored the DPAA SDK drivers under `drivers/net/ethernet/freescale/sdk_{dpaa,fman}` and `drivers/staging/fsl_qbman`. GPL-2.0, individual file headers retained.
- **Mono** built the 6.12 ASK patch set in [`we-are-mono/ASK`](https://github.com/we-are-mono/ASK), the upstream reference.
- **[@mihakralj](https://github.com/mihakralj)** maintains the [6.6 reference translation](https://github.com/mihakralj/ask-ls1046a-6.6) and this producer repo.
- The bucketing, hardening, defconfig fragments, and packaging in `release/` and `scripts/` are original to this repo. GPL-2.0.

Kernel source pulled by `fetch-kernel.sh` comes from kernel.org over HTTPS and is **not** cryptographically verified by these scripts. If end-to-end trust matters for your build, layer a verified-boot-style check before consuming the tarball.