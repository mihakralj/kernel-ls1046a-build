# `release/` — committed source-of-truth for the ASK 6.6.137 kernel

This directory is what a builder consumes. It contains every patch, every SDK source drop, and every defconfig fragment needed to turn a pristine `linux-6.6.137` tarball into a bootable ASK kernel + `.deb` files. No network, no derivation step required — `git clone` and `scripts/run-pipeline.sh --skip-fetch --no-derive --build` is enough.

## Layout

```text
release/
├── README.md                  # this file
├── manifest.json              # provenance pointers (reference + upstream SHAs)
├── ask.config                 # LS1046A/DPAA delta (wins last in the merge_config chain)
├── vyos-base/                 # vendored VyOS defconfig fragments
│   ├── arm64/vyos_defconfig
│   └── *.config               # filesystems, networking, netfilter, …
└── patches/
    ├── vyos/                  # 3 patches — VyOS deltas, applied first
    ├── ask/                   # 8 patches — ASK fast-path hooks (010..080)
    ├── fixes/                 # 5 patches — 6.6.y-specific repairs (090+)
    └── kernel/sdk-sources/    # 266 verbatim NXP SDK driver source files
        ├── arch/arm64/boot/dts/freescale/   # qoriq-bman/qman-portals-sdk.dtsi
        ├── drivers/leds/lp5812/             # leds-lp5812 driver
        ├── drivers/net/ethernet/freescale/sdk_dpaa/
        ├── drivers/net/ethernet/freescale/sdk_fman/
        ├── drivers/staging/fsl_qbman/
        └── include/{linux,uapi/linux/fmd}/
```

## Apply order

Patches apply in fixed order: `vyos/` → `ask/` → `fixes/`. Within each bucket, sort by filename prefix. The `kernel/sdk-sources/` tree is **not** patches — files are dropped verbatim into the kernel tree by `scripts/apply-to-tree.sh`.

For the full patch inventory and purposes, see the [main README](../README.md#patch-inventory).

## Producer invariants (non-negotiable)

`scripts/patch-health.sh --source release` must report exactly:

```text
Pass: 16   Fail: 0
0 SDK conflicts (266 files to install)
```

These numbers change only when a patch is deliberately added/removed or SDK sources are deliberately re-imported. See `.clinerules/50-thresholds-are-authoritative.md`.

## How consumers use it

For the kernel build pipeline (`scripts/apply-to-tree.sh` and friends), `release/` is the **only** input it cares about. There is no separate "derived" or "reference" path in production use — `release/` is the single source of truth.

```bash
# air-gapped / zero-change build from committed release/
scripts/apply-to-tree.sh             # patches + SDK drops onto pristine tree
scripts/build-kernel.sh              # native ARM64 kernel build → work/build/*.deb
```

For consumer integration (`vyos-ls1046a-build`), pin a release tag and download `.deb` artefacts — see the [main README](../README.md#consumer-integration).

## Editing rules

- **`vyos-base/`** — vendored. Re-vendor from the pinned VyOS commit if needed; do not hand-edit.
- **`ask.config`** — LS1046A delta only. `merge_config.sh` runs it last; what's set here wins.
- **`patches/<bucket>/`** — author per `.clinerules/10-patch-authoring.md`: pipe `git diff --no-prefix` through `scripts/normalize-patch.awk` and re-validate with `patch-health.sh`.
- **`patches/kernel/sdk-sources/`** — verbatim NXP SDK drops. Editing them to "fix SDK behavior" is forbidden; fix via an `ask/` or `fixes/` patch that modifies the file after copy.
- **`manifest.json`** — provenance only; not bumped per release iteration. The git tag (`kernel-6.6.137-askN`) is the authoritative version marker.