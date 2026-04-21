# lts_6.6_ls1046a

> The 6.12 kernel that NXP's Application Solutions Kit ships is a beautiful thing. It is also useless to anyone standing on a 6.6 LTS shoreline watching the ship sail past. This repo is the rowboat.

Mono's NXP [ASK (Application Solutions Kit)][ask-upstream] is a patch set that bolts fast-path networking onto Layerscape SoCs: the DPAA SDK driver stack, netfilter-offload hooks, IPsec crypto-engine plumbing, the works. It targets whichever kernel Mono happened to be building against. Right now that's 6.12.

VyOS 1.5/1.6, Debian stable, and every other downstream that cares about a five-year support window lives on 6.6 LTS kernel. So somebody has to do the translation work. And somebody did: [`ask-ls1046a-6.6`](https://github.com/mihakralj/ask-ls1046a-6.6) is a hand-crafted 6.6-compatible port of ASK, living as a static reference tree. Beautiful. Also frozen in time and detached from a main dev.

This repo is the engine that keeps that translation honest. It watches the 6.12 upstream for new commits, classifies them, re-derives the 6.6 patch set, verifies the output applies to a fresh kernel tarball, and builds Debian packages for the NXP LS1046A. All of it driven by one entry point.

CI runs natively on GitHub-hosted **arm64** runners (`ubuntu-24.04-arm`), so the kernel and every userspace `.deb` is a straight native compile. No cross toolchain, no foreign-arch apt juggling, no `dpkg-cross`. The scripts still accept `CROSS_COMPILE=` for anyone who wants to build from an x86_64 dev box.

## Table of contents

- [What lives where](#what-lives-where)
- [The pipeline](#the-pipeline)
- [Scripts, one-liners](#scripts-one-liners)
- [Outputs](#outputs)
- [ASK stack layers](#ask-stack-layers)
- [Quick start](#quick-start)
- [CI and releases](#ci-and-releases)
- [For downstream consumers (vyos-ls1046a-build)](#for-downstream-consumers-vyos-ls1046a-build)
- [License and provenance](#license-and-provenance)

## What lives where

```text
lts_6.6_ls1046a/
├── scripts/              # everything that does work
├── release/              # committed last-known-good artefacts (tracked)
├── work/                 # everything the scripts produce (gitignored)
├── versions.lock         # pinned inputs: upstream SHA, baseline, paths
├── .github/workflows/    # CI: native arm64 build + release on tag push
└── LICENSE               # GPL-2.0, same as VyOS and mono-ASK
```

Three-level split, because mixing source of truth with working scratch is how
you end up rebuilding the world on every PR review.

| Tier | Directory | Tracked? | Purpose |
|---|---|---|---|
| source-of-truth | `release/` | yes | committed patches + SDK sources + config + manifest. A consumer can `git clone` and build. No network needed. |
| fresh derivation | `work/derived/` | no | what the pipeline produced this run. Promoted to `release/` only when it passes every gate. |
| caches | `work/linux-*/`, `work/reference/`, `work/upstream.git/` | no | raw tarball, cloned reference repo, bare mirror of upstream. |

## The pipeline

`run-pipeline.sh` is the only entry point you should call. Everything else
is a building block.

```text
┌─ 1. fetch-kernel.sh ──────┐
├─ 2. fetch-reference.sh    │   independent, parallelizable
└─ 3. fetch-upstream.sh ────┘
            │
            ▼
     4. sync-upstream.sh     classify new commits (T1/T2/T3)
            │
            ▼
     5. derive-patches.sh    rebuild 6.6 patches from 6.12 + delta
            │
            ▼
     6. patch-health.sh      do patches still apply to linux-6.6.y?
            │
            ▼
     7. publish-release.sh   (opt-in) promote work/derived/ → release/
            │
            ▼
     8a. apply-to-tree.sh    (opt-in) wet-run: turn kernel tree into ASK tree
            │
            ▼
         build-kernel.sh     (opt-in) native arm64 → work/build/*.deb
            │
            ▼
     8b. ASK extras          (opt-in, --ask-extras, soft-fail)
         ├── build-ask-modules.sh   (OOT cdx/fci/auto_bridge .ko → single .deb)
         ├── build-ask-iptables.sh  (patched iptables source rebuild + xtables)
         └── build-ask-ppp.sh       (patched ppp + rp-pppoe source rebuilds)
            │
            ▼
     9. publish-binaries.sh  (opt-in) → GitHub Release
```

Each step has a purpose, a precondition, and a single responsibility. When something breaks, you know which step did it. When nothing's changed, each step sees its cache and returns in under a second. That part matters: the fetcher contract is exit 0 (unchanged) / exit 10 (changed / new). The orchestrator reads those and builds the summary.

### Soft-fail policy for ASK extras (step 8b)

The kernel `.debs` are the load-bearing artefact. The extras (modules, patched iptables, patched ppp/rp-pppoe) can fail for distro-specific reasons without that being a reason to lose a green kernel build. `run-pipeline.sh` therefore invokes each extra through `run_step_tolerate_all`: a helper that warns loudly on non-zero exit but never aborts the pipeline. The final summary reports per-layer status (`built`, `skipped (precondition)`, `failed`) and the kernel `.debs` are always uploaded.

### Why this shape

The original question was "what is the right order of calling scripts?" The honest answer: there isn't a linear one. Fetchers are independent. Sync is a gate. Derive is conditional. Health is a verifier. Publish and build are sinks. The pipeline is a DAG with three optional tails.

`run-pipeline.sh` linearizes it so humans don't have to think, but each script still works on its own. Which matters when you're debugging at 3 AM and the last thing you want is a monolith.

## Scripts, one-liners

| Script | Inputs | Outputs | Exit contract |
|---|---|---|---|
| `fetch-kernel.sh [ver]` | kernel.org | `work/linux-<ver>/` + `work/.kernel-version` | 0 unchanged, 10 new/changed |
| `fetch-reference.sh` | `REFERENCE_REPO` | `work/reference/` (full clone) | 0 / 10 |
| `fetch-upstream.sh` | `UPSTREAM_REPO` | `work/upstream.git/` (bare mirror) | 0 / 10 |
| `sync-upstream.sh` | baseline SHA → HEAD delta | classified commit list, written to stderr | 0 clean, 2 T2 work pending |
| `derive-patches.sh` | ref SHA + upstream delta | `work/derived/` tree + `manifest.json` | 0 (status in manifest) |
| `patch-health.sh` | `work/derived/` → `release/` → `work/reference/` | dry-run report, `work/patch-health.txt` | 0 apply clean, 1 rejects |
| `publish-release.sh` | `work/derived/` | `release/` (overwrite) | 0 published, 1 precondition failed, 2 `--check` sees drift |
| `apply-to-tree.sh` | kernel tree + source fallback | kernel tree with SDK copied, patch applied, `.ask-applied` marker | 0 / 1 |
| `build-kernel.sh` | ASK-applied tree | `work/build/*.deb` + `build.log` | 0 / 1 |
| `build-ask-modules.sh` | ASK-applied tree + `work/upstream.git/` | `work/build/ask-modules-*_arm64.deb` (cdx/fci/auto_bridge OOT `.ko`s) | 0 built **or** skipped (SDK precondition), 1 fail |
| `build-ask-iptables.sh` | Debian `iptables` source + `work/upstream.git/` | `work/build/iptables_*+ask*_arm64.deb` (+ `libxtables12`, `libip[46]tc2`, `iptables-dev`) with QOSMARK/QOSCONNMARK baked in | 0 / 1 / 2 (patch fails to apply) |
| `build-ask-ppp.sh` | Debian `ppp` + `rp-pppoe` sources + `patches/{ppp,rp-pppoe}/` | `work/build/ppp_*+ask*_arm64.deb`, `work/build/pppoe_*+ask*_arm64.deb` (NXP ifindex fix, CMM relay) | 0 (any sub-build ok) / 1 (all failed) / 2 (patch rejected) |
| `publish-binaries.sh` | `work/build/` + `release/manifest.json` | GitHub Release tagged `kernel-<ver>-askN` | 0 / 1 |
| `run-pipeline.sh` | all of the above | orchestrated run + summary | 0 ok, 1 health fail, 2 T2-no-derive, 3 needs-review, 4 build fail, 5 publish-bin fail |
| `common.sh` | n/a (sourced) | helpers: classify, split, fetch-state | n/a |
| `split-reference-patch.sh` | `work/reference/patches/kernel/*.patch` | per-file chunk bundles (grooming aid) | out-of-band, never in pipeline |

### Tier classification

`common::classify_path` and `classify_commit` are the single source of truth
for "what counts as kernel patch work":

```text
T1 direct-apply   userspace, out-of-tree modules, lib patches
T2 port required  anything under patches/kernel/* (needs 6.12 → 6.6 port)
T3 meta           README, Makefile, build scripts, everything else
```

When `sync-upstream.sh` sees a T2 commit since the pinned baseline, it exits 2 and the pipeline runs `derive-patches.sh` to rebuild. T1 and T3 commits are noted but don't force a rebuild.

### Fetcher state contract

All three fetchers write `work/.<name>.state` with `ID=<identity>` + `TIMESTAMP=<iso8601>`. Identity is either the kernel version string or a commit SHA. Unchanged since last run → exit 0. New or changed → exit 10. The orchestrator reads the exit codes, not the state files, so the summary is cheap and honest.

## Outputs

### `release/` (committed, consumable)

```text
release/
├── README.md                           # managed by publish-release.sh
├── manifest.json                       # provenance: ref SHA, upstream SHA, counts
├── ask.config                          # kernel config fragment
└── patches/kernel/
    ├── 003-ask-kernel-hooks.patch      # 175 KB monolith, 13 subsystems
    └── sdk-sources/                    # 67 files, NXP-only drivers
        ├── drivers/net/ethernet/freescale/sdk_dpaa/
        ├── drivers/net/ethernet/freescale/sdk_fman/
        ├── drivers/staging/fsl_qbman/
        └── include/...
```

Clone the repo, point `apply-to-tree.sh` at a linux-6.6.y checkout, done.
No network. No derivation. This is the contract with downstream.

### `work/build/` (ephemeral, consumable)

```text
work/build/
├── linux-image-6.6.N-ask_6.6.N-1_arm64.deb         # kernel + dtbs + modules
├── linux-headers-6.6.N-ask_6.6.N-1_arm64.deb       # for OOT modules
├── linux-libc-dev_6.6.N-1_arm64.deb                # userspace headers
├── *.buildinfo, *.changes                          # dpkg provenance
└── build.log                                       # full compile log
```

Built natively on an arm64 runner via `make bindeb-pkg` (or cross-compiled locally with `CROSS_COMPILE=aarch64-linux-gnu-` if you're on an x86_64 dev box — both code paths go through the same scripts). Tested. Stripped of the host-leaking `output_dir` before upload. Gitignored.

### GitHub Releases (permanent, consumable)

Tagged `kernel-<kver>-ask<N>`. Attached: the four kernel `.deb`s above plus, when enabled and their preconditions are met, any of the additional ASK layer `.deb`s listed in [ASK stack layers](#ask-stack-layers). Also attached: `SHA256SUMS` and `manifest.json`. Release notes include the reference SHA, upstream target SHA, SDK source count, and a paste-ready download block for `vyos-ls1046a-build`. This is the URL downstream pins against.

## ASK stack layers

The four kernel `.debs` produced by `build-kernel.sh` cover only what `make bindeb-pkg` emits: the kernel image (with the ASK fast-path hooks compiled in), debug symbols, headers, and libc-dev. Without additional layers, the in-kernel hooks remain **dormant** — every packet still falls through to the Linux slow path because nothing is registered on the hook sites.

The full ASK stack is five layers. Each is a separate optional build that produces its own `.deb` (or set of `.deb`s) and is wired into the pipeline behind a feature flag.

| # | Layer | What it contains | Pipeline flag | Status |
|---|---|---|---|---|
| 0 | **Kernel image** (always) | `linux-image-*`, `linux-headers-*`, `linux-libc-dev`, debug — ASK hooks compiled in | *(default)* | ✅ Shipping |
| 1 | **OOT kernel modules** | `cdx`, `fci`, `auto_bridge` — the drivers that register on the hook sites | `--ask-extras` | ⏸ Blocked (see below) |
| 2 | **Userspace daemons** | `fmc` (FMan configurator), `cmm` (conn-track/manip), `dpa_app` — XML policy → silicon | `--ask-extras` | 🟡 Not yet scripted |
| 3+4 | **Patched `iptables` + xtables plugins** | Single Debian source rebuild: patched iptables binaries **and** `libxt_QOSMARK.so`, `libxt_QOSCONNMARK.so` | `--ask-extras` | 🟢 Shipping |
| 5 | **Patched `ppp` + `rp-pppoe`** | PPP ifindex fix + rp-pppoe CMM relay patches for PPPoE fast-path | `--ask-extras` | 🟢 Shipping |

Legend: ✅ built and released · 🟢 implemented (CI verification pending) ·
🟡 planned · ⏸ precondition blocked.

> Layers 3 and 4 collapse into a single Debian source rebuild because the upstream ASK patch creates exactly the same set of new files needed by both: four new `extensions/libxt_{qos,QOS}{mark,connmark}.c` and their four headers. Building the Debian `iptables` source package with that patch applied produces the patched binary **and** the four `.so` extensions in one coherent, conflict-free set of `.debs`.

### What `--ask-extras` runs

Pipeline step 8b. After a successful kernel build, each extra is attempted in sequence under `run_step_tolerate_all`: a failure in one layer does not block the others or the kernel `.debs`. The summary reports per-layer status (`built`, `skipped (precondition)`, `failed`). Philosophy: ship what builds, flag what doesn't, never lose the kernel over a userspace bug.

### Layer 1/2 precondition: NXP linux-lsdk FMan SDK

Layers 1 and 2 include the upstream ASK Makefile line

```make
include $(srctree)/drivers/net/ethernet/freescale/sdk_fman/ncsw_config.mk
```

`ncsw_config.mk` belongs to the **NXP linux-lsdk FMan SDK subtree** — a proprietary overlay NXP historically shipped separately on top of mainline. The 6.6 reference tree (`mihakralj/ask-ls1046a-6.6`) bundles only a 4-file stub of `sdk_fman/` and does **not** include that file; none of the ASK upstream branches (`master`, `mono-patched`, `mono-patched-openwrt`, `mt-6.12.y`) contain it either.

`build-ask-modules.sh` detects the missing SDK up-front and exits 0 with a clear diagnostic, rather than failing mid-compile. Pipeline summary reports `ask-modules: skipped (NXP FMan SDK not layered — see build log)`.

To enable layers 1 and 2: obtain the NXP linux-lsdk `sdk_fman/` subtree and install it under `release/patches/kernel/sdk-sources/` so that `apply-to-tree.sh` copies it into the kernel tree alongside the existing `sdk_dpaa/` stub. Once `ncsw_config.mk` is present, the precondition gate opens automatically.

### Layers 3/4/5: independent

The patched iptables rebuild (which covers both xtables plugins and the iptables binary) and the pending patched `ppp` / `rp-pppoe` rebuilds consume patches from `work/upstream.git` (`patches/iptables/`, `patches/ppp/`, `patches/rp-pppoe/`) applied to Debian source packages. They do not depend on the FMan SDK and build on any runner with the Debian build toolchain available.

`scripts/build-ask-iptables.sh` implements layers 3+4. Upstream ASK does **not** ship a `patches/iptables/*.patch`; instead it provides the four new xtables extension sources (`libxt_{qos,QOS}{mark,connmark}.c`) and the matching kernel-UAPI headers under `iptables-extensions/`. The script:

1. `apt-get source iptables` into a clean workspace.
2. Copies the eight files from the upstream mirror into the Debian source    tree (extensions auto-discover via the Debian `iptables` build).
3. Synthesises a clean unified diff for provenance, registers it in    `debian/patches/series` for 3.0 (quilt) source format.
4. `dch --newversion <ver>+ask1` and runs `dpkg-buildpackage --build=binary`    natively (or cross if `DEB_HOST_ARCH != arm64`).

Output: the standard Debian iptables `.deb` set (`iptables`, `libxtables12`, `libip4tc2`, `libip6tc2`, `iptables-dev`) rebuilt with the QOSMARK / QOSCONNMARK extensions baked in.

`scripts/build-ask-ppp.sh` implements layer 5. It iterates the two source packages (`ppp`, `rp-pppoe`) independently — each sub-build has its own `debian/patches/0999-ask.patch` extracted from the upstream mirror (`patches/ppp/01-nxp-ask-ifindex.patch`, `patches/rp-pppoe/01-nxp-ask-cmm-relay.patch`). A dry-run gate rejects upfront if a patch no longer applies; partial success (e.g. `ppp` built but `rp-pppoe` failed) still exits 0 so the pipeline proceeds.

## Quick start

### Prerequisites

Running natively on an arm64 host (the CI path):

```bash
apt install -y \
  build-essential libssl-dev bc flex bison libelf-dev \
  fakeroot kmod dpkg-dev rsync cpio \
  debhelper devscripts quilt \
  libmnl-dev libnftnl-dev libnetfilter-conntrack-dev libnfnetlink-dev \
  libpam0g-dev libpcap0.8-dev libsystemd-dev zlib1g-dev ppp-dev \
  git jq curl patch gh
```

Running on an x86_64 dev box (cross-build; scripts honour `CROSS_COMPILE`):

```bash
apt install -y \
  gcc-aarch64-linux-gnu libssl-dev bc flex bison libelf-dev \
  fakeroot kmod dpkg-dev dpkg-cross rsync cpio \
  git jq curl patch gh
sudo dpkg --add-architecture arm64 && sudo apt-get update
# plus :arm64 variants of the -dev libs above if you want to build the
# iptables/ppp extras locally; the kernel itself builds with just
# gcc-aarch64-linux-gnu.
export CROSS_COMPILE=aarch64-linux-gnu-
```

### Typical runs

```bash
# full pipeline, fresh run, no build
./scripts/run-pipeline.sh

# derive + verify + promote to release/
./scripts/run-pipeline.sh --publish

# air-gapped / zero-change build from committed release/
./scripts/run-pipeline.sh --skip-fetch --no-derive --build

# kernel .debs + all ASK layer .debs that their preconditions permit
./scripts/run-pipeline.sh --skip-fetch --no-derive --ask-extras

# the full monty: fetch, derive, verify, publish source, build (all layers),
# publish binaries
./scripts/run-pipeline.sh --publish --ask-extras --release-binaries

# see what would happen without touching anything
./scripts/run-pipeline.sh --ask-extras --release-binaries --dry-run
```

### When something's wrong

```bash
# patches don't apply to latest 6.6.y → patch-health.sh -> exit 1
./scripts/patch-health.sh --source release

# T2 commits piled up upstream → sync-upstream -> exit 2
./scripts/sync-upstream.sh
./scripts/derive-patches.sh

# reconciliation bundles to review → derive-patches -> status=needs_review
ls work/derived/reconciliation/
```

## CI and releases

`.github/workflows/build-and-release.yml`:

- **Push to branch**: build + patch-health, no publish. Catches rot early.
- **`workflow_dispatch`**: manual build; optional publish checkbox.
- **Push tag `kernel-*`**: build and auto-publish the GitHub Release.

The job runs on `ubuntu-24.04-arm` — GitHub's hosted arm64 Linux runner, free for public repos — so the kernel and all userspace `.debs` build natively. No cross toolchain, no `ports.ubuntu.com` pinning, no foreign-arch apt setup: the runner IS arm64. Workflow artefacts are retained 30 days on every run regardless of publish status, so you can always grab the `.deb`s from a build without promoting it.

Tagging protocol:

```bash
# after a successful local run-pipeline --build:
git tag -a kernel-6.6.123-ask1 -m "ASK kernel 6.6.123 rev 1"
git push --tags
# CI takes it from there
```

Bump `-askN` when the same kernel version gets re-released (reference SHA moved, config fragment changed, etc.). Bump kernel version when upstream 6.6.y advances.

## For downstream consumers (vyos-ls1046a-build)

Pin a tag. Download. Verify. Install.

```bash
KERNEL_TAG="kernel-6.6.123-ask1"
gh release download -R mihakralj/lts_6.6_ls1046a "$KERNEL_TAG" \
    --pattern 'linux-*.deb' \
    --pattern 'SHA256SUMS' \
    --pattern 'manifest.json' \
    -D /tmp/ask-kernel/
(cd /tmp/ask-kernel && sha256sum -c SHA256SUMS)
# inspect provenance
jq . /tmp/ask-kernel/manifest.json
# install into your rootfs / ISO build
dpkg -i /tmp/ask-kernel/linux-image-*.deb /tmp/ask-kernel/linux-headers-*.deb
```

No git dependency. No derivation step on your end. No surprise upstream bumps: the tag is immutable. When this repo advances, your lockfile decides when to consume it.

If you want the source-level artefacts instead (to patch in-tree), clone this repo at the tagged commit and read `release/`. Same hashes, same provenance, different consumption model.

## License and provenance

GPL-2.0, matching both upstream projects this work stands on:

- [`vyos/vyos-build`][vyos-build] (GPL-2.0)
- [`we-are-mono/ASK`][ask-upstream] (GPL-2.0)

See [`LICENSE`](./LICENSE) for the full text.

Attribution where it's due:

- **NXP** authored the DPAA SDK drivers under `drivers/net/ethernet/freescale/sdk_{dpaa,fman}` and `drivers/staging/fsl_qbman`. Those files are licensed under GPL-2.0 with individual file headers.
- **Mono** built the 6.12 ASK patch set in [`we-are-mono/ASK`][ask-upstream], which is the derivation source for the hooks patch here.
- **[@mihakralj](https://github.com/mihakralj)** maintains the [6.6 reference translation][ref-repo]. This repo's monolithic `003-ask-kernel-hooks.patch` comes from that work.
- The orchestration, derivation engine, and packaging scripts in `scripts/` are original to this repo. Same GPL-2.0. Same rules.

Kernel sources pulled by `fetch-kernel.sh` come straight from `kernel.org` and carry their own upstream licences unchanged. We don't redistribute the kernel, we patch it.

[ask-upstream]: https://github.com/we-are-mono/ASK
[ref-repo]: https://github.com/mihakralj/ask-ls1046a-6.6
[vyos-build]: https://github.com/vyos/vyos-build