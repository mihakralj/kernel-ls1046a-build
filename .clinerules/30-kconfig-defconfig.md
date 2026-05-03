# Rule: Kconfig & Defconfig Discipline

The kernel configuration is composed from **defconfig fragments**, never from a hand-edited `.config`.

## Sources of truth

```
release/vyos-base/arm64/vyos_defconfig         # base VyOS arm64 defconfig
release/vyos-base/00-filesystems.config
release/vyos-base/01-executable-file-formats.config
release/vyos-base/02-module-signing.config
release/vyos-base/10-networking.config
release/vyos-base/11-encapsulation.config
release/vyos-base/11-wwan.config
release/vyos-base/20-netfilter.config
release/ask.config                             # ASK-specific symbol overrides
```

These fragments are merged in lexical order by the build pipeline. **All** persistent configuration changes go through these files.

## Hard rules

1. **Never edit a generated `.config`** in `work/linux-6.6.137/.config` and expect the change to persist — it will be overwritten on the next build.
2. **Never carry config changes inside a `*.patch`** under `release/patches/`. Symbol toggles belong in fragments.
3. **Required `=y` symbols** (enforced by `release/ask.config`):
   - `CONFIG_FSL_SDK_FMAN=y`
   - `CONFIG_FSL_SDK_DPAA_ETH=y`
   - `CONFIG_FSL_SDK_DPA=y`
4. **Forbidden symbols** (must remain unset / `# CONFIG_X is not set`):
   - `CONFIG_FSL_FMAN`
   - `CONFIG_FSL_DPAA_ETH`
   - the mainline `drivers/soc/fsl/qbman/` driver
5. When a fragment changes, run `scripts/diff-vyos-config.sh` to confirm the delta vs the previous green build is intentional. Surface the diff in the commit message.

## When you think you need to "just toggle one symbol"

You don't. Locate the appropriate fragment (or `release/ask.config`), edit it there, commit with the `vyos:` or `ask:` prefix matching its scope, and re-run `patch-health.sh`.