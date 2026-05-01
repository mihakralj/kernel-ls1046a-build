# Rule: NXP SDK Drivers (the why behind ASK)

ASK ships **NXP SDK drivers**, not mainline. This is non-negotiable — the SDK is required for the userspace ABI consumed by ASK userspace tools (USDPAA, FMC, `dpa_ipsec`, `fmlib`, `dpa_app`, `fmc`).

## Symbol map (use these, NEVER the mainline equivalents)

| Required (`=y`) | Path | Mainline equivalent — DO NOT USE |
|---|---|---|
| `CONFIG_FSL_SDK_FMAN` | `drivers/net/ethernet/freescale/sdk_fman/` | `fman/` (`CONFIG_FSL_FMAN`) |
| `CONFIG_FSL_SDK_DPAA_ETH` | `drivers/net/ethernet/freescale/sdk_dpaa/` (fsl_mac, fsl_dpa) | `dpaa/` (`CONFIG_FSL_DPAA_ETH`) |
| `CONFIG_FSL_SDK_DPA` | `drivers/staging/fsl_qbman/` | `drivers/soc/fsl/qbman/` |

Never propose:
- Switching to mainline FMan/DPAA/QBMan.
- Removing or disabling any of the three `FSL_SDK_*` symbols.
- "Modernizing" the SDK to the component framework.

## Build order matters — `sdk_fman/` before `sdk_dpaa/`

`sdk_dpaa/mac.c:202` returns `-ENODEV` (not `-EPROBE_DEFER`) when `fm_bind()` finds FMan not yet probed. Mainline doesn't have this — it uses the component framework. Therefore, in `drivers/net/ethernet/freescale/Makefile`, the `obj-$(CONFIG_FSL_SDK_FMAN) += sdk_fman/` line MUST appear **before** `obj-$(CONFIG_FSL_SDK_DPAA_ETH) += sdk_dpaa/`. Patch `ask/010-ask-fman-dpaa-ehash.patch` enforces this order; do not reverse it.

## SDK source drops are verbatim

Files under `release/patches/kernel/sdk-sources/<mirrored-path>` (264 files) are dropped into the kernel tree by `scripts/apply-to-tree.sh`. They are:

- **NOT** patches — never converted to `.patch` form.
- **NOT** to be edited to fix SDK behavior — fix via an `ask/` or `fixes/` patch that modifies the file after copy.
- Refreshed only by re-importing from a known NXP SDK reference tag.

The `264 files to install` count from `patch-health.sh` is an invariant. If a refresh adds/removes files, the count assertion in CI must be updated **deliberately**, with the change called out in the commit message.

## Patch ownership for SDK behavior

| Symptom | Fix location |
|---|---|
| Probe order / driver init bug | `ask/010-ask-fman-dpaa-ehash.patch` (Makefile order) or new `fixes/` patch |
| FMan/DPAA fast-path hooks | `ask/010..030` |
| Conntrack / netfilter offload | `ask/050..060` |
| 6.6.y kernel API drift breaking SDK | `fixes/090+` |