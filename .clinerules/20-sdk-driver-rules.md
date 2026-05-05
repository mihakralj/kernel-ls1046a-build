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

## SDK source drops — verbatim by default, direct edits permitted under marker discipline

Files under `release/patches/kernel/sdk-sources/<mirrored-path>` (266 files) are dropped into the kernel tree by `scripts/apply-to-tree.sh`. They are:

- **NOT** patches — never converted to `.patch` form.
- Refreshed only by re-importing from a known NXP SDK reference tag.

### Direct-edit policy (ask26+)

The previous rule "**NOT** to be edited to fix SDK behavior — fix via an `ask/` or `fixes/` patch" was relaxed at ask26. The upstream branch ASK currently mirrors (`nxp-qoriq/linux ask-6.6-port`, the one-shot 6.6.52 port) is a **dead branch**: NXP has stated no further updates will land. Maintaining a parallel `fixes/` patch stack on top of dead upstream sources adds complexity (malformed-hunk failure mode, off-by-one `@@` arithmetic, two places to read for the truth) without buying any rebase safety.

Direct edits to files under `release/patches/kernel/sdk-sources/` are therefore **permitted** when ALL of the following hold:

1. The upstream source of the file is a dead branch (currently: `ask-6.6-port`). If a live upstream exists, the change still goes through `fixes/`.
2. The fix is a defect in the NXP source itself (compile error, undefined reference, mis-gated code), not a 6.6.y kernel API drift. API drift fixes still belong in `fixes/`.
3. **Every edit is annotated with an `ASK-edit` marker comment** of the form:

   ```c
   /* ASK-edit (askNN): <one-line rationale> */
   ```

   placed immediately above the changed line / block. For deletions, leave the marker comment in place of the removed code so the audit trail stays in-tree.

4. `grep -rn 'ASK-edit' release/patches/kernel/sdk-sources/` enumerates **every** delta from upstream. This grep is the canonical audit surface — if you edit an SDK file without a marker, the audit trail is broken.
5. The commit subject uses the `sdk-edits:` prefix (not `sdk:` — that prefix remains for verbatim re-imports).

### What still belongs in `fixes/`

- Kernel-API-drift repairs (e.g., `fixes/102` ioremap_cache_ns shim, `fixes/103` MIN/MAX guard, `fixes/104` phylink shims, `fixes/105` skb_recycle shim) — these are mainline 6.6.y deltas, not NXP source bugs.
- Cross-cutting symbol-export adds that touch many SDK files for one logical change, where a single patch is more reviewable than N scattered direct edits.
- Anything where the edit needs to be re-applied after a future SDK re-import.

### File count invariant

The `266 files to install` count from `patch-health.sh` is still an invariant. Direct edits do not change file count. If a refresh adds/removes files, the count assertion in CI must be updated **deliberately**, with the change called out in the commit message.

## Patch ownership for SDK behavior

| Symptom | Fix location |
|---|---|
| Probe order / driver init bug | `ask/010-ask-fman-dpaa-ehash.patch` (Makefile order) or new `fixes/` patch |
| FMan/DPAA fast-path hooks | `ask/010..030` |
| Conntrack / netfilter offload | `ask/050..060` |
| 6.6.y kernel API drift breaking SDK | `fixes/090+` |