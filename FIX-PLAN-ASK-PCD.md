# Fix Plan — ASK PCD MURAM exhaustion + Kernel Panic Hardening

Captured 2026-04-28 from on-target ASK health-check on Mono Gateway running `kernel-6.6.135-vyos` ISO `2026.04.28-1914-rolling`.

## ASK health-check baseline

```
ASK health check complete: 54 passed, 5 failed, 1 skipped (59 active checks)
```

The 5 failures collapse to **2 root causes**, plus **1 latent kernel bug** discovered while diagnosing them.

---

## Problem A — `dpa_app` PCD apply fails (rc=65280)

### Failed checks (3 of 5)
- `[FAILED] dpa_app applied PCD configuration (failed rc=65280)`
- `[FAILED] BMan fragment buffer pool located by CDX` (cascaded — pool is created by `dpa_app`)
- `[FAILED] no ASK driver probe/init/bind failures (3 hit(s))` (counts the FM-PCD MAJOR errors)

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

The on-target `fmc` build does **not** know those attributes — running `fmc -a` prints
`WARN: Unknown attribute 'external'` / `WARN: Unknown attribute 'aging'` for every hashtable. The unknown attributes are silently dropped, so every hash table falls back to MURAM and the allocator runs out at `AllocStatsObjs`.

### Fix surface (NOT in this repo)

| Layer | Repo | Action |
|---|---|---|
| `fmc` userspace | `vyos-ls1046a-build` | Rebuild `fmc` from the ASK userspace tree that has `external`/`aging` hashtable attribute support. The patch lives in NXP's ASK fmc source; it isn't in the LS1043A reference fmc tarball that the build currently packages. |
| `cdx_pcd.xml` budget | `ask-ls1046a-6.6/cdx/` | If rebuilding `fmc` is not possible, an interim fix is to drop `statistics="byteframe"` and reduce `max="512"` → `max="32"` for the 16 hashtables. Reduces flow capacity ~16× but lets PCD load. |
| `dpa_ipsec` skip | n/a | Already SKIPped — passes once Problem A clears |

### Why we cannot fix this on the running instance

We tried: trimmed `cdx_pcd.xml` and ran `fmc -a` manually. The PCD apply hit the same MURAM exhaustion, then the SDK FMan driver kernel-panicked during rollback (Problem C below). Mono panic-rebooted. **Do not retry runtime fmc apply** — every failed apply risks another panic until Problem C is patched.

---

## Problem B — `cmm` daemon dies on start

### Failed checks (2 of 5)
- `[FAILED] cmm process running`
- `[FAILED] cmm.service active`

### Evidence
```
cmm[6410]: cmmCtInit:3258 fci_open() failed, Protocol not supported
systemd[1]: cmm.service: Deactivated successfully.
```

`fci.ko` is loaded and `/dev/cdx_ctrl` exists. The error is from `socket(AF_NETLINK, SOCK_RAW, NETLINK_FCI)` returning `EPROTONOSUPPORT`. The FCI netlink protocol family isn't registered.

### Fix surface (NOT in this repo)

| Layer | Repo | Action |
|---|---|---|
| FCI netlink registration | `ask-ls1046a-6.6/cdx/control_socket.c` | Verify `netlink_kernel_create()` is reached on `fci.ko` init and that the protocol number matches the cmm-side `<linux/fci.h>` UAPI. Likely a port-from-5.4-to-6.6 regression in the netlink init sequence. |

---

## Problem C — Latent NULL deref in SDK FMan PCD rollback path (NEW — found while diagnosing A)

### Trigger
When `dpa_app` (or any `fmc -a` invocation) runs `FM_PCD_PrsLoadSw` and gets back `0x10013` (`E_INVALID_STATE`) because of MURAM exhaustion, the cleanup IOCTL path runs `FM_PORT_DeletePCD` → `DetachPCD`, which calls `FmPcdIsHcUsageAllowed(p_FmPort->h_FmPcd)`. At that point `p_FmPort->h_FmPcd` is **NULL** because the port had no PCD attached yet — the apply failed before binding.

### Evidence
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

The `0x6948` virtual address = NULL + offset 0x6948 of `t_FmPcd::h_Hc` (matches the `(t_FmPcd*)h_FmPcd)->h_Hc` deref inside `FmPcdIsHcUsageAllowed`).

### Code path

`drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Port/fm_port.c:1874`:
```c
if (FmPcdIsHcUsageAllowed(p_FmPort->h_FmPcd))   // p_FmPort->h_FmPcd is NULL here
    FmPcdHcSync(p_FmPort->h_FmPcd);
```

`drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/fm_pcd.c:871`:
```c
bool FmPcdIsHcUsageAllowed(t_Handle h_FmPcd)
{
    ASSERT_COND(h_FmPcd);                                 // ASSERT under SDK
    return FmIsHcUsageAllowed(((t_FmPcd*)h_FmPcd)->h_Hc); // NULL deref
}
```

`ASSERT_COND` in this SDK build is **not a hard panic on its own** (it's defined to print a banner) — but the next statement immediately dereferences NULL, which on arm64 is a fatal kernel paging fault.

### Fix (THIS REPO — `lts_6.6_ls1046a/release/patches/fixes/`)

Make `FmPcdIsHcUsageAllowed` defensive: return `FALSE` when handed NULL, instead of trusting the caller.

This is safer than fixing the call sites because the function is exported and called from several places (port detach, PCD destroy, several port-modify paths). One change covers all of them.

Patch file: `release/patches/fixes/096-sdk-fman-pcd-null-handle-guard.patch`

```diff
--- a/drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/fm_pcd.c
+++ b/drivers/net/ethernet/freescale/sdk_fman/Peripherals/FM/Pcd/fm_pcd.c
@@ -870,7 +870,8 @@
 
 bool FmPcdIsHcUsageAllowed(t_Handle h_FmPcd)
 {
-ASSERT_COND(h_FmPcd);
+    if (!h_FmPcd)
+        return FALSE;
 
     return FmIsHcUsageAllowed(((t_FmPcd*)h_FmPcd)->h_Hc);
 }
```

### Why this is safe and correct

1. **Semantically correct**: the function returns "is HC (Host Command) usage allowed on this PCD?". If the PCD handle is NULL, no PCD is attached, so HC usage cannot be allowed → `FALSE`.
2. **Caller in `DetachPCD` already guards on the return value** — it only calls `FmPcdHcSync` if true. `FALSE` → skip the sync, which is the correct behaviour when no PCD was attached.
3. **No ABI change** — same prototype, same return type, only relaxes the precondition.
4. **Matches the kernel coding style** — defensive null checks are standard in driver code; the SDK's `ASSERT_COND` here is a porting artefact from the (FreeRTOS-style) target abstraction layer where `ASSERT_COND` would halt before the deref.

### Smoke-test plan

After landing the patch and rebuilding the kernel:

1. Boot mono with current (broken) `cdx_pcd.xml`.
2. Confirm boot still completes with `cdx_module_init::start_dpa_app failed rc 65280 (continuing anyway)` and 5 ports `u/u`.
3. From a shell, invoke `sudo /usr/local/bin/fmc -c /etc/cdx_cfg.xml -p /etc/cdx_pcd.xml -d /etc/fmc/config/hxs_pdl_v3.xml -s /etc/cdx_sp.xml -a` — same command that panicked the box previously.
4. Expected: `fmc` returns non-zero, dmesg shows the same FM-PCD MURAM allocation errors, **no kernel panic**, system stays up.

---

## Execution plan for this repo (`lts_6.6_ls1046a`)

- [ ] Write `release/patches/fixes/096-sdk-fman-pcd-null-handle-guard.patch`
- [ ] Run `bash scripts/patch-health.sh --source release` and confirm `Pass: 14   Fail: 0`
- [ ] Apply patch into a fresh tree and visually verify `FmPcdIsHcUsageAllowed` body in `fm_pcd.c`
- [ ] Commit + tag `kernel-6.6.135-ask15` (push tag only, per AGENTS.md)
- [ ] After producer release builds, bump kernel pin in `vyos-ls1046a-build/versions.lock` and rebuild ISO
- [ ] On mono, run the smoke test (panic-prone fmc invocation) — must NOT panic the box
- [ ] (Out of scope here) Problems A and B are tracked in `vyos-ls1046a-build` and `ask-ls1046a-6.6` respectively