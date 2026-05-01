# Fix Plan — `cmm: fci_open() failed, Protocol not supported` — **RESOLVED in ask50**

> **Status:** ✅ Resolved as of `kernel-6.6.135-ask50` (commit `a006bf2`, tagged 2026-05-01).
> This document is retained as **history of how the fix evolved across ask48 → ask49 → ask50**, since the wrong-but-plausible attempts each taught something durable about kbuild and the 6.6 vs ASK-6.12 ABI gap.

## TL;DR (the fix that shipped)

A **single-line defconfig change** in `release/vyos-base/10-networking.config`:

```diff
-CONFIG_NET_KEY=m
+CONFIG_NET_KEY=y
```

Combined with the pre-existing patch `release/patches/fixes/097-ask-fci-nlkey-narrow-gate.patch`, this makes the kernel register `NETLINK_KEY=32` at boot, so userspace `cmm`'s `fci_open(FCILIB_KEY_TYPE)` (which calls `socket(AF_NETLINK, SOCK_RAW, NETLINK_KEY)`) no longer returns `EPROTONOSUPPORT`.

## The symptom

```text
cmm[1312]: cmmCtInit:3258 fci_open() failed, Protocol not supported
systemd[1]: cmm.service: Main process exited, code=exited, status=1/FAILURE
```

`ask-check` reported:
```
[FAILED] cmm process running
[FAILED] cmm.service active
```

`cmm.service` is `Type=forking` with `RestartPreventExitStatus` set such that after 3 failed restarts systemd marks the unit "Deactivated successfully" and then "Started" — so `systemctl is-active cmm.service` reports `active` while the process is actually gone. ask-check correctly catches both the dead process and the fake-active unit.

## The root cause

`cmm`'s `fci_open(FCILIB_KEY_TYPE)` does:
```c
socket(AF_NETLINK, SOCK_RAW, 0x20 /* NETLINK_KEY=32 */)
```

The kernel returns `EPROTONOSUPPORT` because protocol 32 is not registered. The job of registering it belongs to `release/patches/fixes/097-ask-fci-nlkey-narrow-gate.patch`, which adds:

- a new file `net/key/ask_fci_nlkey.c` with a `late_initcall` that calls `netlink_kernel_create(&init_net, NETLINK_KEY, &cfg)`,
- `obj-$(CONFIG_ASK_FCI_NLKEY) += ask_fci_nlkey.o` in `net/key/Makefile`,
- `CONFIG_ASK_FCI_NLKEY` Kconfig stanza (`depends on NET_KEY`, default n).

`CONFIG_ASK_FCI_NLKEY=y` was correctly set in `release/vyos-base/10-networking.config`. **But the file never compiled into vmlinux.**

### The kbuild trap

In `net/Makefile`:
```makefile
obj-$(CONFIG_NET_KEY) += key/
```

With `CONFIG_NET_KEY=m` (the kernel.org default carried via VyOS defconfig), this expands to `obj-m += key/`, putting kbuild into **module-only descent** for `net/key/`. Per `Documentation/kbuild/makefiles.rst §3.4`, every `obj-y` line inside a subdirectory entered via `obj-m += subdir/` is silently dropped. So `obj-$(CONFIG_ASK_FCI_NLKEY) += ask_fci_nlkey.o` (= `obj-y += …` because the symbol is `=y`) was **discarded** during the kbuild pass.

Confirmed on the running ask49 device:

```bash
zcat /proc/config.gz | grep -E 'NET_KEY|ASK_FCI_NLKEY'
#   CONFIG_NET_KEY=m
#   CONFIG_ASK_FCI_NLKEY=y
ls /sys/module/ask_fci_nlkey 2>&1
#   No such file or directory
grep ask_fci /proc/kallsyms
#   (empty)
cat /proc/net/netlink | awk '{print $2}' | sort -u | grep -w 32
#   (no match)
dmesg | grep 'ASK FCI'
#   (empty — the late_initcall never ran)
```

### Reference confirmation

`work/reference/config/kernel/defconfig` (NXP/ASK 6.12) ships:

```text
CONFIG_NET_KEY=y
CONFIG_INET_IPSEC_OFFLOAD=y
```

In the reference architecture, `NETLINK_KEY` is registered inside `net/key/af_key.c::ipsec_pfkey_init()` via an `#ifdef NLKEY_SUPPORT` block (gated on `CONFIG_INET_IPSEC_OFFLOAD`). With `NET_KEY=y`, `af_key.c` is built into vmlinux and `ipsec_pfkey_init()` runs as a regular initcall. The reference has no kbuild trap.

We can **not** mirror the reference's `INET_IPSEC_OFFLOAD=y` path on 6.6, because the IPsec offload data path inside patch 040 references `xfrm_state` fields (`curr_time`, `offloaded`) that don't exist on 6.6.y. Re-enabling fails to compile. So the narrow gate (`CONFIG_ASK_FCI_NLKEY` + a dedicated `ask_fci_nlkey.c`) is the right architecture for us — but it must be reachable by `obj-y`. The reference's `NET_KEY=y` is what made that work, and it's the same single-line change that fixed us.

## Evolution of the fix (ask48 → ask49 → ask50)

| Iteration | Approach | Outcome |
|---|---|---|
| **ask47 (broken in production)** | Original ASK 6.12 patch 040 had `NETLINK_KEY` registration inside `af_key.c` gated on `#ifdef NLKEY_SUPPORT` (defined when `CONFIG_INET_IPSEC_OFFLOAD`). With `INET_IPSEC_OFFLOAD=n` (forced because the data path doesn't compile on 6.6), the registration was compiled out. | `cmm.service` failed `EPROTONOSUPPORT`. |
| **ask48** | Add a Kconfig definition for `CONFIG_INET_IPSEC_OFFLOAD` and turn it on. | Build broke: `xfrm_state` lacks `curr_time` / `offloaded` fields the data path expects. Reverted. |
| **ask49** | Replace the ASK-6.12 in-`af_key.c` registration with a self-contained new file `net/key/ask_fci_nlkey.c` gated by a fresh `CONFIG_ASK_FCI_NLKEY=y`. Keep `INET_IPSEC_OFFLOAD=n`. | Patch-health green; CI built; image deployed; `cmm` still failed. Investigation found the file was never compiled (the kbuild trap above). |
| **ask50** ✅ | Flip `CONFIG_NET_KEY=m → =y` in `release/vyos-base/10-networking.config`. Patch 097 unchanged. | `obj-y += ask_fci_nlkey.o` is now honored. `late_initcall` runs at boot, `NETLINK_KEY=32` is registered, `cmm.service` comes up. |

The lesson is durable: **a `=y` symbol inside a subdirectory entered via `obj-m += subdir/` is silently dropped**. Any future patch that adds a built-in object inside `net/key/` (or any other parent-gated subdir) must verify the parent gate is `=y`, not `=m`.

## Verification on mono after ask50 deploy

```bash
zcat /proc/config.gz | grep NET_KEY
#   CONFIG_NET_KEY=y                                # was =m

cat /proc/net/netlink | awk '{print $2}' | sort -u | grep -w 32
#   32                                              # was missing

grep ask_fci /proc/kallsyms | head
#   ffff... t ask_fci_nlkey_init                    # was empty
#   ffff... t ask_fci_nlkey_rcv

dmesg | grep 'ASK FCI'
#   ASK FCI: NETLINK_KEY=32 socket registered       # was empty

systemctl is-active cmm.service
#   active                                          # genuinely active now

/usr/local/bin/ask-check | tail -10
#   "cmm process running" + "cmm.service active" both PASS
```

## Related artefacts

- Patch: `release/patches/fixes/097-ask-fci-nlkey-narrow-gate.patch` (unchanged from ask49)
- Defconfig: `release/vyos-base/10-networking.config` line 25 (`CONFIG_NET_KEY=y`)
- Commit: `a006bf2` — `vyos: NET_KEY=y to honor ASK_FCI_NLKEY built-in registration`
- Tag: `kernel-6.6.135-ask50`
- Agent docs: [`AGENTS.md` § Reference-Aligned Defconfig Invariants](./AGENTS.md#reference-aligned-defconfig-invariants), [`AGENTS.md` § Two-chain failure model](./AGENTS.md#two-chain-failure-model-post-ask49)
- Qdrant `agent_memory` collection — record `ASK kernel FCI NETLINK_KEY=32 registration`

## Why this doc is kept

The wrong-but-plausible iterations (ask48's `INET_IPSEC_OFFLOAD=y` attempt; ask49's right-architecture-but-trapped-by-kbuild gate) each represent a non-obvious failure mode that an agent could plausibly re-attempt while diagnosing a similar symptom. Keeping the trail visible is cheaper than rediscovering it from scratch.

The companion document for the **other** chain of `ask-check` failures (Chain 2 — `dpa_app` PCD MURAM exhaustion) is [`FIX-PLAN-ASK-PCD.md`](./FIX-PLAN-ASK-PCD.md). That chain is owned by `vyos-ls1046a-build`, not this repo, and is **still open** as of ask50.