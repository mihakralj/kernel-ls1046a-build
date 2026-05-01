# Rule: Workspace Layout & Cross-Repo Routing

This VS Code workspace contains **two sibling repositories** that together implement the producer/consumer split for the ASK kernel + VyOS image. Both are checked out under `/root/`:

| Path | Role | Branch | Publishes |
|---|---|---|---|
| `/root/lts_6.6_ls1046a` (this repo) | **Producer** — Linux 6.6.135 + VyOS + NXP SDK DPAA/FMan/QBMan kernel | `lts-6.6-ls1046a` | `kernel-6.6.135-askN` GitHub Releases (kernel tarball, headers, modules) |
| `/root/vyos-ls1046a-build` | **Consumer** — VyOS ARM64 ISO/image builder, ASK userspace, FMan PCD config, DPDK/VPP integration | `main` | VyOS ISO + eMMC image |

The consumer pins a specific producer release via `vyos-ls1046a-build/data/ask-kernel.pin`. CI in the consumer downloads the kernel artifacts from the pinned `kernel-6.6.135-askN` tag.

## When you are working in `lts_6.6_ls1046a` (this repo)

The `.clinerules/` files numbered `00..60` apply. Scope is strictly:

- Kernel source patches (`release/patches/{vyos,ask,fixes}/`)
- Verbatim NXP SDK driver drops (`release/patches/kernel/sdk-sources/`)
- Kernel defconfig fragments (`release/vyos-base/`, `release/ask.config`)
- Kernel build / packaging scripts (`scripts/`)
- Producer CI (`.github/workflows/build-and-release.yml`)
- Producer docs (`README.md`, `AGENTS.md`, `FIX-PLAN-*.md`, `FIXES.md`, `release/manifest.json`)

## When you are working in `vyos-ls1046a-build`

That repo has its own `AGENTS.md` (very large — covers DPAA1, VPP, AF_XDP, DPDK, SFP+, GPIO, U-Boot env, fmlib/fmc, accel-ppp, vyos-postinstall, migration scripts, etc.). Read it there. Scope is strictly:

- VyOS image / ISO recipe (live-build hooks, packages.chroot)
- Userspace ASK components (`ASK/`, `ask-ls1046a-6.6/`, `bin/ci-build-*.sh`)
- `fmc` / `fmlib` builds and patches
- FMan PCD XML (`/etc/cdx_pcd.xml`, `data/fmc/`)
- DTS (`data/dtb/mono-gateway-dk*.dts`)
- VPP / DPDK / AF_XDP integration (`vyos-1x-*` patches)
- Consumer CI (`.github/workflows/self-hosted-build.yml`, `auto-build.yml`)
- The `data/ask-kernel.pin` file pinning the producer tag

## Cross-repo routing — Two-chain failure model

Boot-time `ask-check` failures collapse into two **independent** chains. Routing the symptom to the correct repo is mandatory before making any change.

### Chain 1 — kernel-side → fix in `/root/lts_6.6_ls1046a` (this repo)

Symptoms:
- `cmm process running [FAILED]`, `cmm.service active [FAILED]`
- `socket(AF_NETLINK, SOCK_RAW, NETLINK_KEY=32) = -EPROTONOSUPPORT`
- SDK driver `probe/init/bind` failures (sdk_fman, sdk_dpaa, fsl_qbman)
- `dev_get_drvdata(port@XXXXX) failed -22` from `fsl_mac` probes
- Anything originating in the kernel before userspace (FMan/DPAA driver init, QBMan portal setup, NETLINK protocol registration, kernel module signing rejection)
- Build/link errors against 6.6.y kernel APIs

Routing: edit `release/patches/{ask,fixes}/`, `release/vyos-base/*.config`, or `release/ask.config`; cut a new `kernel-6.6.135-askN` tag.

### Chain 2 — userspace-side → fix in `/root/vyos-ls1046a-build` (sibling repo, NOT here)

Symptoms (canonical signature from boot log):
- `fm_cc.c:4377 AllocStatsObjs Memory Allocation Failed` / `MURAM allocation for statistics ADs`
- `fm_cc.c:4756 MatchTableSet Memory Allocation Failed`
- `fm_cc.c:7743 FM_PCD_HashTableSet Unexpected NULL Pointer`
- `lnxwrp_ioctls_fm.c:3479 LnxwrpFmPcdIOCTL Invalid Value`
- `dpa_app applied PCD configuration (failed rc=65280)`
- `cdx_create_fragment_bufpool::failed to locate eth bman pool`
- `cdx_init_frag_module(...) create_fragment_bufpool failed`
- `BMan fragment buffer pool located by CDX [FAILED]`
- `cdx_module_init::start_dpa_app failed rc 11`
- `cdx_module_init::dpa_ipsec start failed`
- VPP/AF_XDP no traffic, DPDK GROUP linker drops, accel-ppp build, fmlib/fmc ABI mismatch
- DTS / SFP+ / GPIO / thermal / fan / udev port naming
- VyOS image install / `vyos-postinstall` / U-Boot env / boot.scr / `vyos.env`
- Migration scripts, configd caching, `is_live_boot()`, kexec managed-params

Routing: switch to `/root/vyos-ls1046a-build`, follow that repo's `AGENTS.md`, edit there, push there. **Do not commit a producer-side change in `lts_6.6_ls1046a` to mask a Chain-2 symptom**, even if the kernel is the component reporting the error — the kernel is doing its job correctly when MURAM is exhausted by an oversized `cdx_pcd.xml` or when `dpa_app` SIGSEGVs from a stale `libfm.a`/`libfmc.a`.

## Working across both repos in one workspace

Both trees are checked out under `/root/`, so tool calls (read, write, search, command) can target either repo from a session whose `cwd` is the other:

```bash
# From this repo, work on the consumer
ls /root/vyos-ls1046a-build/...
read /root/vyos-ls1046a-build/AGENTS.md
git -C /root/vyos-ls1046a-build status
```

When you make edits, keep the **commit boundary aligned with the repo whose files changed** — never stage or commit producer files (`/root/lts_6.6_ls1046a/...`) and consumer files (`/root/vyos-ls1046a-build/...`) in the same commit. They belong to two independent histories with different remotes, branches, and CI.

When you push, follow each repo's own discipline:
- This repo (`lts_6.6_ls1046a`): see `00-tag-discipline.md` — tag-only pushes for releases, never branch+tag in the same `git push`.
- Consumer repo: see its own `AGENTS.md` — `main` only, no auto-push, dispatch `self-hosted-build.yml` for CI.

## The pin file

`/root/vyos-ls1046a-build/data/ask-kernel.pin` is the contract surface between the two repos. It records the producer tag (`kernel-6.6.135-askN`) the consumer image is built against. When this repo cuts a new `askN` and the consumer needs to consume it, the consumer-side commit bumps `data/ask-kernel.pin` — that is a `vyos-ls1046a-build` commit, not a commit in this repo.

## Forbidden cross-repo anti-patterns

1. Mixing producer and consumer file changes in a single commit.
2. Re-cutting a `kernel-6.6.135-askN` tag in `lts_6.6_ls1046a` to "fix" a Chain-2 symptom that the consumer should handle (wastes ~22 min ARM64 CI minutes per occurrence — see `00-tag-discipline.md`).
3. Mirroring or copy-pasting the consumer's `AGENTS.md` into this repo's `AGENTS.md` — they have intentionally different scopes.
4. Adding a `data/ask-kernel.pin` file to `lts_6.6_ls1046a` (it lives only in the consumer).
5. Bumping `data/ask-kernel.pin` to a producer tag that has not actually been published as a GitHub Release.
