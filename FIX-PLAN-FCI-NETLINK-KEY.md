# Fix Plan — `cmm: fci_open() failed, Protocol not supported`

Producer-side fix for the FCI/NETLINK_KEY registration regression that
keeps `cmm.service` from coming up on mono.

## TL;DR

Two kconfig symbols (`CONFIG_INET_IPSEC_OFFLOAD`,
`CONFIG_INET6_IPSEC_OFFLOAD`) are referenced as `#ifdef` gates inside
ASK patch `040-ask-xfrm-ipsec-offload.patch` but have **no Kconfig
definition** anywhere in the patch set, and are **not set** in
`release/vyos-base/10-networking.config`. Their gated code includes the
entire `nlkey_socket` registration path inside `net/key/af_key.c` — the
piece that calls `netlink_kernel_create(..., NETLINK_KEY, ...)`. With
the gate undefined, NETLINK_KEY (=32) is never registered with the
kernel netlink subsystem, and `cmm`'s `fci_open(FCILIB_KEY_TYPE, …)` →
`socket(AF_NETLINK, SOCK_RAW, 32)` returns `EPROTONOSUPPORT`.

The producer kernel must either:
1. Add a real Kconfig definition for those two symbols and turn them on
   in `release/vyos-base/10-networking.config`, **or**
2. Replace the `#ifdef NLKEY_SUPPORT` gates in patch 040 with
   `#ifdef CONFIG_XFRM_OFFLOAD` (which is already `=y` in
   `10-networking.config`) so that the existing config drives the gate.

Option 1 is the minimum-surface fix and matches the original NXP intent
(IPSEC offload is a tri-state choice, not implied by `XFRM_OFFLOAD`).

## Evidence

### Live system reproduction (mono, 6.6.135-vyos #1 SMP, 2026-04-28)

```
$ sudo strace -e trace=socket /usr/bin/cmm -f /etc/config/fastforward -n 1024
30965 socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER) = 3
30965 socket(AF_NETLINK, SOCK_RAW, 0x1e /* NETLINK_FF=30   */) = 4
30965 socket(AF_NETLINK, SOCK_RAW, 0x1e /* NETLINK_FF=30   */) = 5
30965 socket(AF_NETLINK, SOCK_RAW, 0x20 /* NETLINK_KEY=32  */) = -1 EPROTONOSUPPORT
cmm[…]: cmmCtInit:3258 fci_open() failed, Protocol not supported
```

So `NETLINK_FF` (registered by `fci.ko` via `netlink_kernel_create`) is
fine. The protocol that fails is `NETLINK_KEY=32`, used by cmm for the
IPSEC SA/flow control plane.

### Running kernel config

```
$ zcat /proc/config.gz | grep -E 'IPSEC_OFFLOAD|NET_KEY|XFRM_OFFLOAD'
CONFIG_NET_KEY=m
CONFIG_NET_KEY_MIGRATE=y
# CONFIG_INET_IPSEC_OFFLOAD is not set      ← the gate is OFF
# CONFIG_INET6_IPSEC_OFFLOAD is not set     ← the gate is OFF
CONFIG_XFRM_OFFLOAD=y                       ← (set by 10-networking.config)
```

### Where the gate lives

`release/patches/ask/040-ask-xfrm-ipsec-offload.patch` modifies
`net/key/af_key.c` like this (excerpt, ~line 33):

```c
+#if defined(CONFIG_INET_IPSEC_OFFLOAD)|| defined(CONFIG_INET6_IPSEC_OFFLOAD)
+#include <net/ip6_route.h>
+#define NLKEY_SUPPORT 1
+#else
+#undef NLKEY_SUPPORT
+#endif
+
+#ifdef NLKEY_SUPPORT
+...
+/* netlink NETLINK_KEY socket */
+struct sock *nlkey_socket = NULL;
+...
+#endif
```

…and later (in the rest of the same patch) all of `ipsec_nlkey_init`
(which calls `netlink_kernel_create(&init_net, NETLINK_KEY, &cfg)`),
`ipsec_nlkey_send`, `ipsec_nlkey_rcv`, the `pfkey_init` hook, etc.

The patch contains 102 hunks referencing `NLKEY` / `NETLINK_KEY` /
`netlink_kernel_create`, all gated by `NLKEY_SUPPORT`, all dead code
in the current build because neither `CONFIG_INET_IPSEC_OFFLOAD` nor
`CONFIG_INET6_IPSEC_OFFLOAD` is defined in any Kconfig in-tree or by
patch 040 itself.

### Where the gate is *not* defined

```
$ grep -rE 'config\s+INET6?_IPSEC_OFFLOAD' work/linux-6.6.135/  # post-apply
(no matches)
```

Stock 6.6 has no `INET_IPSEC_OFFLOAD` symbol, and patch 040 never adds
one. The symbols exist only as preprocessor literals.

### Userspace evidence

`vyos-ls1046a-build/data/ask-userspace/cmm/src/conntrack.c:3253`:

```c
ctx->fci_catch_handle = fci_open(FCILIB_FF_TYPE,  NL_FF_GROUP);    /* OK */
ctx->fci_handle       = fci_open(FCILIB_FF_TYPE,  0);              /* OK */
ctx->fci_key_catch_handle = fci_open(FCILIB_KEY_TYPE, NL_KEY_ALL_GROUP);
                                                  /* ← EPROTONOSUPPORT */
ctx->fci_key_handle   = fci_open(FCILIB_KEY_TYPE, 0);
```

`vyos-ls1046a-build/data/ask-userspace/fci/lib/include/libfci.h`:

```
#define FCILIB_FF_TYPE   1   /* NETLINK_FF  = 30 */
#define FCILIB_KEY_TYPE  2   /* NETLINK_KEY = 32 */
```

So the userspace contract is: `cmm` requires both NETLINK_FF and
NETLINK_KEY to come up; the kernel must register both.

## Root cause summary

ASK patch 040 has been in the producer since the 5.4-→-6.6 port, but the
Kconfig wiring needed to *enable* its IPSEC offload code path was lost in
the port. The symbols `CONFIG_INET_IPSEC_OFFLOAD` and
`CONFIG_INET6_IPSEC_OFFLOAD` exist only as preprocessor literals in the
patch, never as real Kconfig entries, so the build can never turn them
on. The result is that `af_key.c`'s `nlkey_socket` registration is
permanently `#ifdef`-removed, and userspace IPSEC offload control plane
is structurally broken in the current ASK kernel.

## Fix surface — three options

### Option A — Real Kconfig + defconfig (RECOMMENDED)

1. Extend `release/patches/ask/040-ask-xfrm-ipsec-offload.patch`
   (or add a small companion patch in `release/patches/fixes/`) so it
   adds two new entries to `net/xfrm/Kconfig`:

   ```
   config INET_IPSEC_OFFLOAD
       bool "IPv4 IPsec offload (NXP/ASK)"
       depends on XFRM && INET
       default n
       help
         Enables NXP CAAM/ASK IPv4 IPsec offload. Required for the
         ASK fast-path conntrack/SA control plane (registers
         NETLINK_KEY and the af_key.c offload hooks).

   config INET6_IPSEC_OFFLOAD
       bool "IPv6 IPsec offload (NXP/ASK)"
       depends on XFRM && IPV6
       default n
       help
         IPv6 counterpart of INET_IPSEC_OFFLOAD.
   ```

2. Add to `release/vyos-base/10-networking.config`:

   ```
   CONFIG_INET_IPSEC_OFFLOAD=y
   CONFIG_INET6_IPSEC_OFFLOAD=y
   ```

3. Confirm `CONFIG_NET_KEY=m` stays as today and ensure `af_key` is
   loaded at boot:

   - Easiest path: keep `CONFIG_NET_KEY=m` and add `af_key` to
     `data/scripts/ask-modules-load.sh` (in
     `vyos-ls1046a-build`) so `af_key` is `modprobe`d before `cmm`
     starts.
   - Alternative: change to `CONFIG_NET_KEY=y` so it auto-inits.

The "real Kconfig" path is preferred because the gate is actually a
build-time choice (the offload code links against CAAM PDB updates and
xfrm internal helpers), not a runtime tunable.

### Option B — Replace the gate with `CONFIG_XFRM_OFFLOAD` (smaller patch)

`CONFIG_XFRM_OFFLOAD=y` is already set in
`release/vyos-base/10-networking.config`. We could rewrite patch 040 so
every `#if defined(CONFIG_INET_IPSEC_OFFLOAD) || defined(CONFIG_INET6_IPSEC_OFFLOAD)`
becomes `#ifdef CONFIG_XFRM_OFFLOAD`. That activates the NLKEY path on
every build that has XFRM_OFFLOAD on (which is what we want for ASK).

Risk: `CONFIG_XFRM_OFFLOAD` is also set on generic/distro kernels (it's
the gate for hardware crypto offload more broadly). On a non-LS1046A
build, the patch's NLKEY code would compile in even though it's NXP-
specific. For the producer (which only ever builds for LS1046A) this is
fine; for any future cross-platform reuse of this kernel it's not.

### Option C — Hard-define `NLKEY_SUPPORT` (smallest patch, brittle)

Replace the gate block in `af_key.c` with `#define NLKEY_SUPPORT 1`
unconditionally. Same effect as Option B but indistinguishable from a
hack; not recommended.

## Implementation plan (this repo)

We pick **Option A**.

| Step | Action | Files |
|------|--------|-------|
| 1 | Add Kconfig entries for `INET_IPSEC_OFFLOAD` and `INET6_IPSEC_OFFLOAD` | new `release/patches/fixes/096-net-key-ipsec-offload-kconfig.patch` |
| 2 | Enable them in vyos-base | `release/vyos-base/10-networking.config` |
| 3 | Validate the patch set still applies cleanly | `bash scripts/patch-health.sh --source release` |
| 4 | Verify the running kernel exposes NETLINK_KEY | post-build dmesg + `cat /proc/net/netlink` shows protocol 32 |
| 5 | Tag, push, release | `kernel-6.6.135-ask48` |
| 6 | Consumer rebuild | `vyos-ls1046a-build`: bump `data/ask-kernel.pin`, ensure `af_key` is loaded before `cmm` (extend `ask-modules-load.sh`) |

### Step-1 patch (sketch)

```diff
diff --git a/net/xfrm/Kconfig b/net/xfrm/Kconfig
@@
 config XFRM_OFFLOAD
     bool

+config INET_IPSEC_OFFLOAD
+    bool "IPv4 IPsec offload (NXP/ASK)"
+    depends on XFRM && INET
+    default n
+    help
+      Enables NXP CAAM/ASK IPv4 IPsec offload control plane.
+      Registers NETLINK_KEY and the af_key.c nlkey_socket hooks
+      consumed by the ASK userspace cmm/dpa_ipsec daemons.
+
+config INET6_IPSEC_OFFLOAD
+    bool "IPv6 IPsec offload (NXP/ASK)"
+    depends on XFRM && IPV6
+    default n
+    help
+      IPv6 counterpart of INET_IPSEC_OFFLOAD.
+
 config XFRM_ALGO
     tristate
     select XFRM
```

### Step-2 defconfig delta

```diff
--- a/release/vyos-base/10-networking.config
+++ b/release/vyos-base/10-networking.config
@@
 CONFIG_NET_KEY=m
 CONFIG_NET_KEY_MIGRATE=y
+CONFIG_INET_IPSEC_OFFLOAD=y
+CONFIG_INET6_IPSEC_OFFLOAD=y
 CONFIG_XFRM_OFFLOAD=y
```

### Step-6 consumer-side hookup (cross-repo follow-up)

In `vyos-ls1046a-build/data/scripts/ask-modules-load.sh` add a
`modprobe af_key` step (with `|| :` tolerance for kernels that have
NET_KEY=y) just before `cdx`/`fci` are loaded. `af_key` is what
actually runs the new `ipsec_nlkey_init` and registers the kernel-side
NETLINK_KEY socket.

## Smoke-test plan

1. Patch + defconfig change applied cleanly (`patch-health.sh` reports
   `Pass: 14   Fail: 0`).
2. New release ISO boots on mono via TFTP.
3. Post-boot:
   ```
   $ sudo lsmod | grep -E 'af_key|fci|cdx|auto_bridge'
   $ cat /proc/net/netlink | awk '$2==30 || $2==32'   # 30=FF 32=KEY both registered
   $ sudo systemctl status cmm
   ● cmm.service: active (running)
   $ sudo /usr/local/bin/ask-check
   …no fci_open / cmm failures…
   ```
4. ask-check failures drop from 5 → 2 (the remaining two are Problem A
   MURAM exhaustion, tracked separately in `FIX-PLAN-ASK-PCD.md`).

## Why this is safe

- The added Kconfig symbols default `n`, so other consumers of this
  kernel are untouched until a defconfig opts in.
- Code activated by the gate is the existing patch-040 NLKEY code that
  has been live in the producer source for the entire ASK 5.4 lifetime
  — it just hasn't been compiled in for ASK 6.6. We're not writing new
  netlink code; we're un-disabling existing, vendor-shipped code.
- If the new code path turns out to misbehave, reverting is a one-line
  defconfig change (set the symbols `n`) — no kernel rebuild.

## Out of scope (handled in follow-up repos)

- `vyos-ls1046a-build/data/scripts/ask-modules-load.sh` change to
  `modprobe af_key` before `cmm`.
- `cmm.service` `After=` ordering already correctly waits for
  `ask-modules-load.service`; no unit edit required as long as
  ask-modules-load.sh modprobes af_key.