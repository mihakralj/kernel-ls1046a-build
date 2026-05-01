# Fix Plan — ASK PCD MURAM Exhaustion (Chain-2, consumer-side)

**Status as of `kernel-6.6.135-ask50` (2026-05-01):** Only **Problem A** remains open, and it routes to the consumer repo `vyos-ls1046a-build`. Problems B and C have been resolved in the producer (this repo).

Captured 2026-04-28 from on-target ASK health-check on Mono Gateway. Original baseline:

```
ASK health check complete: 54 passed, 5 failed, 1 skipped (59 active checks)
```

The 5 failures collapsed to 2 root causes plus 1 latent kernel bug. Two of those three are now fixed.

---

## Problem A — `dpa_app` PCD apply fails (rc=65280)  [STILL OPEN — consumer-side]

### Failed checks
- `[FAILED] dpa_app applied PCD configuration (failed rc=65280)`
- `[FAILED] BMan fragment buffer pool located by CDX` (cascaded — pool is created by `dpa_app`)
- `[FAILED] no ASK driver probe/init/bind failures (≥1 hit(s))` (counts the FM-PCD MAJOR errors)

### Evidence
```
fm_cc.c:4377 AllocStatsObjs       Memory Allocation Failed
fm_cc.c:4756 MatchTableSet        Memory Allocation Failed
fm_cc.c:7743 FM_PCD_HashTableSet  Unexpected NULL Pointer        (cascaded)
lnxwrp_ioctls_fm.c:3479           IOCTL FM PCD Invalid Value     (cascaded)
cdx_module_init::start_dpa_app failed rc 65280 (continuing anyway)
cdx_create_fragment_bufpool::failed to locate eth bman pool      (cascaded)
```

### Root cause
`/etc/cdx_pcd.xml` requests far more PCD state than fits in the 384 KiB FMan internal MURAM:

- 16 classifications × `max="512"` keys × `statistics="byteframe"` ≈ 16 K stats objects
- 18 hashtables tagged `external="yes" aging="yes"` — those attributes mean *push the bucket array off-MURAM into DDR-backed USDPAA memory*

The on-target `fmc` build does **not** know those attributes — running `fmc -a` prints `WARN: Unknown attribute 'external'` / `WARN: Unknown attribute 'aging'` for every hashtable. The unknown attributes are silently dropped, so every hash table falls back to MURAM and the allocator runs out at `AllocStatsObjs`.

The kernel SDK FMan driver is correctly reporting MURAM exhaustion. **No producer-side change can help.**

### Fix surface (NOT in this repo)

| Layer | Repo | Action |
|---|---|---|
| `fmc` userspace | `vyos-ls1046a-build` | Rebuild `fmc` from the ASK userspace tree that has `external`/`aging` hashtable attribute support. The patch lives in NXP's ASK fmc source; it isn't in the LS1043A reference fmc tarball that the build currently packages. |
| `cdx_pcd.xml` budget | `ask-ls1046a-6.6/cdx/` | If rebuilding `fmc` is not possible, an interim fix is to drop `statistics="byteframe"` and reduce `max="512"` → `max="32"` for the 16 hashtables. Reduces flow capacity ~16× but lets PCD load. |

### Why retry on the running instance is unsafe (HISTORICAL)

We tried trimming `cdx_pcd.xml` and running `fmc -a` manually. The PCD apply hit MURAM exhaustion, then the SDK FMan driver kernel-panicked during rollback (Problem C below). Mono panic-rebooted. **This panic path is now patched in the producer (commit `2fa9133`)** — runtime `fmc -a` retry is safe again, but PCD apply will still fail until the consumer-side fix lands.

---

## Problem B — `cmm` daemon dies on start  [RESOLVED in `kernel-6.6.135-ask50`]

**See `FIX-PLAN-FCI-NETLINK-KEY.md` for the full history.**

TL;DR: `cmm`'s `fci_open(FCILIB_KEY_TYPE)` opens `socket(AF_NETLINK, SOCK_RAW, NETLINK_KEY=32)` and got `EPROTONOSUPPORT` because no kernel module registered proto 32. Patch `release/patches/fixes/097-ask-fci-nlkey-narrow-gate.patch` adds `net/key/ask_fci_nlkey.c` (a `late_initcall` that registers `NETLINK_KEY=32`) and was wired in. **However**, until ask50 it was silently dropped by a kbuild trap: `release/vyos-base/10-networking.config` had `CONFIG_NET_KEY=m`, which makes `net/Makefile` enter `net/key/` via `obj-m += key/` (module-only descent), and any `obj-y` line inside `net/key/Makefile` is silently dropped. Reference NXP/ASK 6.12 ships `CONFIG_NET_KEY=y`. Flipping `=m → =y` was the one-line ask50 fix.

---

## Problem C — Latent NULL deref in SDK FMan PCD rollback path  [RESOLVED]

Resolved by commit `2fa9133` — `sdk_fman: harden FmPcdIsHcUsageAllowed against NULL handle`. That commit lives directly in `release/patches/kernel/sdk-sources/drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/fm_pcd.c` (this is verbatim NXP SDK source; per `.clinerules/20-sdk-driver-rules.md`, fixes for SDK behaviour are allowed to be applied directly to the SDK drop when they correct an obvious upstream defect).

### What was broken
When `dpa_app` (or any `fmc -a` invocation) ran `FM_PCD_PrsLoadSw` and got back `0x10013` (`E_INVALID_STATE`) due to MURAM exhaustion, the cleanup path ran `FM_PORT_DeletePCD` → `DetachPCD`, which called `FmPcdIsHcUsageAllowed(p_FmPort->h_FmPcd)` with `h_FmPcd == NULL` (no PCD had been bound yet because the apply failed before binding).

```
ASSERT_COND failed [CPU00, sdk_fman/Peripherals/FM/Pcd/fm_pcd.c:873 FmPcdIsHcUsageAllowed]
Unable to handle kernel paging request at virtual address 0000000000006948
Call trace:
  FmPcdIsHcUsageAllowed+0x6c/0x84
  DetachPCD+0x64/0x1a8
  FM_PORT_DeletePCD+0x6c/0x4f4
  LnxwrpFmPortIOCTL+0x12c8/0x310c
Internal error: Oops [#1] SMP
Kernel panic - not syncing: Fatal exception
```

### What was changed
`FmPcdIsHcUsageAllowed` now returns `FALSE` on a NULL handle instead of asserting and dereferencing:

```c
bool FmPcdIsHcUsageAllowed(t_Handle h_FmPcd)
{
    if (!h_FmPcd)
        return FALSE;

    return FmIsHcUsageAllowed(((t_FmPcd*)h_FmPcd)->h_Hc);
}
```

Caller (`DetachPCD`) already guards on the return value, so `FALSE` → skip `FmPcdHcSync`, which is correct when no PCD was attached. No ABI change.

---

## Summary

| Problem | Status | Where fixed |
|---|---|---|
| A — PCD MURAM exhaustion / `dpa_app` rc=65280 | OPEN | `vyos-ls1046a-build` (consumer): rebuild `fmc` with `external`/`aging` support, OR trim `cdx_pcd.xml` budget |
| B — `cmm` `fci_open` `EPROTONOSUPPORT` | RESOLVED in ask50 | This repo: patch `fixes/097` + `CONFIG_NET_KEY=y`. See `FIX-PLAN-FCI-NETLINK-KEY.md`. |
| C — NULL-handle panic in `FmPcdIsHcUsageAllowed` | RESOLVED | This repo: SDK source hardened (commit `2fa9133`). |

This document is kept as the routing record for Problem A. When the consumer-side fix lands, this file can be archived.