# `release/vyos-base/` — vendored VyOS kernel configuration

Read-only snapshot of VyOS's kernel configuration artefacts, copied verbatim from
the VyOS `vyos-build` repo (`scripts/package-build/linux-kernel/config/`).

## Files

| Path | Origin |
|---|---|
| `arm64/vyos_defconfig` | `config/arm64/vyos_defconfig` — arm64 base defconfig |
| `00-filesystems.config` | `config/00-filesystems.config` — fs modules (overlayfs, fuse, etc.) |
| `01-executable-file-formats.config` | `config/01-executable-file-formats.config` |
| `02-module-signing.config` | `config/02-module-signing.config` |
| `10-networking.config` | `config/10-networking.config` — core networking |
| `11-encapsulation.config` | `config/11-encapsulation.config` |
| `11-wwan.config` | `config/11-wwan.config` |
| `20-netfilter.config` | `config/20-netfilter.config` — nftables/iptables modules |

## How VyOS composes them

VyOS's `build-kernel.sh` runs something equivalent to:
```
merge_config.sh arch/arm64/configs/vyos_defconfig config/*.config
```
then `make olddefconfig`. The snippets override/extend the arm64 defconfig
with the features VyOS's CLI depends on at runtime.

## How ASK consumes them

`scripts/build-kernel.sh` (wet path) uses the same `merge_config.sh` chain,
then appends our LS1046A-specific delta `release/ask.config` last so it wins.
That way every VyOS-visible kernel knob matches stock VyOS 1.5, while we keep
the DPAA/FMan SDK drivers the LS1046A needs.

## Updating

Do not hand-edit. Re-vendor after bumping the pinned VyOS commit with:
```
./scripts/sync-vyos-base.sh     # (to be added — see lts_6.6_ls1046a roadmap)
```
