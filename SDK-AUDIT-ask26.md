# SDK Source Audit — post-ask26

Date: 2026-05-05
Scope: all 266 files under `release/patches/kernel/sdk-sources/` (NXP SDK
drivers + LED driver + UAPI + DTSI), as imported from
`nxp-qoriq/linux ask-6.6-port` @ `6d0b77e9`.

This audit identifies defensive-coding defects and optimization
opportunities **NOT** already addressed by the existing patch stack
(`release/patches/fixes/` 093..112) or ASK-edit ask26 markers. Findings
are ranked by impact. Each entry includes a suggested fix and a routing
note (`fix-here` / `ASK-edit` / `policy`).

Routing legend:

- **ASK-edit** — direct edit under `release/patches/kernel/sdk-sources/...`
  with `/* ASK-edit (askNN): rationale */` marker (per ask26 policy).
- **fix-here** — patch in `release/patches/fixes/` (cross-cutting / API drift).
- **policy** — non-code change (Kconfig, Makefile, doc, defconfig).

Severity:

- **P0** — likely UAF, panic, OOB write, or userspace privilege boundary.
- **P1** — leak / deadlock under failure path, stale-API build break,
  ABI hazard.
- **P2** — micro-optimization, style, hardening that is not currently
  exploitable.

Status legend per item: `[ ]` open · `[x]` fixed in a later askN.

---

## P0 — Userspace boundary / OOB / panic

### A1. `fsl_usdpaa.c` — copy_*_user return value treated as -EFAULT [P0] [x ask27]

Many call sites return `int ret = copy_from_user(...); if (ret) return ret;`
**`copy_*_user` returns the count of uncopied bytes (positive on
failure)**, so the syscall returns a positive value rather than `-EFAULT`,
which userspace treats as a successful short read. Affected: `id_alloc`,
`id_release`, `id_reserve`, `dma_used`, `ioctl_pcd_*` (multiple),
approximately lines 913, 925, 951, 990, 1322, 2310, others.

Fix: `if (copy_from_user(dst, src, n)) return -EFAULT;`
Routing: **ASK-edit**. Replace each pattern in
`release/patches/kernel/sdk-sources/drivers/staging/fsl_qbman/fsl_usdpaa.c`,
mark each with `/* ASK-edit (askNN): copy_from_user returns uncopied-byte count, must map to -EFAULT */`.

### A2. `lnxwrp_ioctls_fm.c` — `ASSERT_COND` on user-supplied bounds [P0] [x ask27]

`src/wrapper/lnxwrp_ioctls_fm.c:1230-1231` uses `ASSERT_COND(num_of_keys
<= IOC_FM_PCD_MAX_NUM_OF_KEYS)` to bound a user-supplied count BEFORE
copying user data into a stack/heap key/mask buffer. `ASSERT_COND`
compiles out under `DISABLE_ASSERTIONS` (the production config),
permitting OOB write into `keys[k]` / `masks[k]` at lines ~1245, ~1258
via `copy_from_user`.

Fix: replace each `ASSERT_COND(...)` that gates user input with a
runtime check returning `-EINVAL`. Audit all `ASSERT_COND` uses in
`src/wrapper/` and convert any that gate `copy_from_user` size or
loop bound.

Routing: **ASK-edit** in `lnxwrp_ioctls_fm.c`,
`lnxwrp_ioctls_fm_compat.c`, and any sibling `*_ioctls_*.c`.

### A3. `qman_driver.c` — `sp++` after `list_add_tail` [P0/dead-code] [x ask27]

`qman_driver.c:223` and `:255` increment a pointer (`sp++`, `lni++`) that
already belongs to a linked list, after the previous iteration kzalloc'd
a new element and linked it. The increment is dead because the next
iteration overwrites `sp` with a fresh kzalloc; however, on a hand-edit
near these lines an OOB deref of the post-increment value is one
keystroke away. The current expression is also misleading reviewers.

Fix: drop the `sp++;` / `lni++;` lines (the loop variable is `i`,
not the element pointer).

Routing: **ASK-edit** in `qman_driver.c`.

### A4. `dpaa_eth_sg.c` — DMA unmap type mismatch on SGT cleanup [P0]

`dpaa_eth_sg.c:1424` (sgt error unwind): the loop starts at `j = 0` and
uses `dma_unmap_page()` for every entry, but `sgt[0]` was mapped via
`dma_map_single(skb->data, ...)` at line 1362 — different DMA mapping
type. On `dma_debug=on` kernels this triggers a WARN; on production it
silently mis-syncs the linear-buffer cache line.

Fix: unmap entry 0 with `dma_unmap_single`, loop entries 1..nfrags
with `dma_unmap_page`. Verify `sgt_map_failed` falls through correctly
and unmaps the just-mapped sgt buffer too (currently leaks).

Routing: **ASK-edit** in `dpaa_eth_sg.c` (one file, 1 hunk).

### A5. `dpaa_eth_sg.c` — A050385 realign leaks page on `build_skb` fail [P0]

`dpaa_eth_sg.c:1043` (errata A050385 realignment path): `build_skb(npage_addr,
nsize)` failure jumps to `err:` which calls `dev_kfree_skb(nskb)` while
`nskb == NULL` — guarded by NULL but the `npage` allocation is leaked
(`put_page(npage)` missing).

Fix: on `build_skb` failure, `put_page(npage); return ERR_PTR(-ENOMEM);`
(or follow the existing conventions in the same TU for build_skb fail
paths).

Routing: **ASK-edit** in `dpaa_eth_sg.c`.

---

## P1 — Lockup / leak / build break

### B1. `fm_cc.c` — spinlock leak in `DequeueNodeInfoFromRelevantLst` [P1]

`Peripherals/FM/Pcd/fm_cc.c:5099-5104`: takes
`XX_LockIntrSpinlock(h_Spinlock)` then on the empty-list early return
calls **`XX_RestoreAllIntr(intFlags)`** — restores the IRQ flags but
never releases the spinlock. The next acquire deadlocks the CPU.

Fix: `XX_UnlockIntrSpinlock(h_Spinlock, intFlags); return;`

Routing: **ASK-edit** in `fm_cc.c`. Audit the whole file for the same
pattern (`XX_RestoreAllIntr` without preceding `XX_UnlockIntrSpinlock`
on a path that took the lock).

### B2. `fman_test.c` — pre-6.4 `class_create()` two-arg signature [P1]

`src/wrapper/fman_test.c:1602`: `class_create(THIS_MODULE, DEV_FM_TEST_NAME)`
— this is the pre-6.4 signature; kernel 6.6 takes a single `name`
argument. Build fails when the test wrapper is enabled (currently gated
out, but enabled by the FMT_FOLDER build path).

Fix: drop `THIS_MODULE`. The companion `class_destroy()` is
signature-compatible. Cf. `lnxwrp_fm.c:1282` already migrated.

Routing: **ASK-edit** in `fman_test.c`.

### B3. `qman_high.c` — `qman_create_cgr` reads `cgr_state` without zeroing [P1]

`qman_high.c:3060-3100` (and the matching `qman_modify_cgr` site):
`qman_query_cgr(cgr, &cgr_state)` is called only when `opts != NULL`,
but the subsequent `local_opts.cgr.cscn_targ = cgr_state.cgr.cscn_targ |
TARG_MASK(p)` runs unconditionally on the < REV30 path. When `opts ==
NULL`, `cgr_state` is uninitialized stack data.

Fix: zero-init `cgr_state` at declaration, OR move the `cscn_targ`
write under `if (opts)`.

Routing: **ASK-edit** in `qman_high.c`. Also audit other
`qman_query_cgr` / `qman_query_*` callers for the same pattern.

### B4. UAPI — `typedef uint8_t ioc_header_field_*_t` pollution [P1 ABI]

`include/uapi/linux/fmd/net_ioctls.h` and siblings define typedefs at
file scope (`typedef uint8_t ioc_header_field_ppp_t`, ...). This pollutes
userspace namespace (typedef leaks into every TU that ever includes
`<linux/fmd/...>`). LSP-aware userspace tooling (clangd) flags shadowing
in subsequent declarations using `ioc_header_field_*_t` as locals.

Lower-impact ABI-wise (sizeof is still 1) but a footgun.

Fix: change to `#define IOC_HEADER_FIELD_PPP_T uint8_t` or move the
typedef to a non-public sub-include under `#ifdef __KERNEL__`. UAPI
break-class is **soft** (typedefs are not part of stable ABI), but
existing userspace builds against this header may fail to compile if
they have a name collision.

Routing: **policy + ASK-edit** if changed.

### B5. ioctl number sizeof drift on UAPI struct edits [P1 ABI]

ASK already learned this lesson at ask24 (`fixes/112` extends
`ioc_fm_pcd_hash_table_params_t` and the `_IOR/_IOW` ioctl number
changes accordingly). Add a CI check: a script that walks
`include/uapi/linux/fmd/Peripherals/*.h`, computes
`sizeof(struct ioc_fm_pcd_*_t)` against a snapshot, and fails the build
if any struct's size changed without an explicit "intended" entry in
`release/manifest.json`.

Fix: new `scripts/check-uapi-sizes.sh` invoked from `patch-health.sh`.

Routing: **policy** — new script + manifest entry. Mediums-effort but
catches a whole class of silent ABI breaks.

### B6. `dpaa_eth_sg.c` (Rx replenish) — `kmalloc(GFP_DMA|GFP_ATOMIC)` failure leak [P1]

`dpaa_eth_sg.c:162` (Rx bpool replenish hot path). On `dma_map_single`
failure after a successful `build_skb`, the already-allocated `new_buf`
leaks (no `kfree(new_buf)` on the error unwind).

Fix: extend `handle_fail` to free `new_buf` if `dma_map_single` failed
after `build_skb`.

Routing: **ASK-edit** in `dpaa_eth_sg.c`.

### B7. Allocations inside `XX_LockIntrSpinlock` (audit) [P1]

`XX_LockIntrSpinlock` is a spinlock-with-IRQ-save. Sleeping inside it
panics under `CONFIG_DEBUG_ATOMIC_SLEEP=y` (which ASK builds with).
ASK has hit this already (`fixes/107` for `dpa_alloc`, `fixes/108` for
`dpa_get_channel`).

Open audit list (subagent flagged but did not fix):

- `fm_cc.c:5099` (already in B1; same lock).
- Entire `Peripherals/FM/Pcd/fm_pcd.c` and `fm_port.c` need a
  systematic grep for `XX_Malloc` / `kmalloc(GFP_KERNEL` / `mutex_lock`
  inside `XX_LockIntrSpinlock` ... `XX_UnlockIntrSpinlock` ranges.

Suggested follow-up: `scripts/audit-locks.sh` — awk pass that emits
every `XX_LockIntrSpinlock` block with body-line summary, manually
review.

Routing: **ASK-edit** as defects surface.

### B8. Resource leak audit on probe error paths [P1]

ASK-style probe error unwinds use `goto err_X` labels in roughly half
the SDK probe functions. Subagent flagged inconsistent unwinds in
`dpaa_eth_base.c`, `dpaa_eth_proxy.c`, `offline_port.c` (BMan pool
refcount on remove path), `dpaa_ethercat.c` (no init failure unwind).

Fix per file: convert the cascading `if (rc) goto out;` chain to the
`goto err_unwind_X;` pattern with explicit `kfree`/`put_device`/
`bman_pool_destroy` at each label.

Routing: **ASK-edit** per file.

---

## P2 — Optimization / hardening

### C1. NAPI Rx path uses `dev_kfree_skb` not `napi_consume_skb` [P2]

`dpaa_eth_sg.c` Rx error paths inside NAPI poll call `dev_kfree_skb()`.
NAPI hot path should use `napi_consume_skb()` (skb cache reuse).

Fix: replace under NAPI poll context.

Routing: **ASK-edit** in `dpaa_eth_sg.c`.

### C2. Missing `prefetch()` of next FD in Rx batch [P2]

`dpaa_eth_sg.c` Rx loop pulls one FD from the dequeue ring per iteration
without prefetching the next FD's payload header. On 1046A (4 cores,
LPDDR4 ~6ns), prefetch saves ~30ns/frame at small-packet rates.

Fix: `prefetch(skb->data + 64)` after `build_skb`, before
`napi_gro_receive`.

Routing: **ASK-edit**, low-risk perf nudge.

### C3. `__read_mostly` annotations missing [P2]

Globals never written after init (e.g. `bman_dev`, `qman_dev`, FMan
config tables, ethtool stats names) lack `__read_mostly`. Costs cache
lines in dirty SMP traffic on the small heap.

Fix: annotate with `__read_mostly`.

Routing: **ASK-edit** across the SDK trees.

### C4. `.cinh` / `.cena` portal mappings — `dma-coherent` audit [P2]

`arch/arm64/boot/dts/freescale/qoriq-{bman,qman}-portals-sdk.dtsi` —
the SDK relies on portal CINH (cache-inhibited) and CENA
(cache-enabled) windows being mapped with the matching attribute. The
DTSI files don't carry `dma-coherent` on the parent bus; the driver
handles this in code (see `fixes/102` ioremap_cache_ns shim).

Verify: every portal node has a `reg` pair (CINH addr/size + CENA
addr/size), and the bus parent's `#address-cells` / `#size-cells`
match what `qman_driver.c` / `bman_driver.c` parse via
`of_address_to_resource(np, 0, ...)` and `(np, 1, ...)`.

Fix if needed: add `coherent-bus` or per-node `dma-coherent` and
correlate with the `arch/arm64/include/asm/io.h` shim from `fixes/102`.

Routing: **policy + ASK-edit** depending on outcome.

### C5. lp5812 LED driver — clientdata staleness on EPROBE_DEFER [P2]

`drivers/leds/lp5812/leds-lp5812.c:592` (lp5812_remove): if
`lp5812_register_leds()` failed mid-loop on first probe, then probe was
deferred and re-ran successfully, `i2c_set_clientdata()` retained the
old `lp5812_led*` array pointer. Remove path uses stale `led->chip`.

Fix: store `chip` (not `led`) in `i2c_set_clientdata`, or set
`each->chip = chip` BEFORE calling `lp5812_init_led`.

Routing: **ASK-edit** in `leds-lp5812.c`.

### C6. lp5812 — `led_cdev->dev->platform_data = led` post `devm_led_classdev_register` [P2]

`leds-lp5812.c:357`: writes through `led_cdev->dev->platform_data` after
`devm_led_classdev_register`. By that point sysfs is live and the
sibling fields may be read by a concurrent `brightness_set` from
userspace. Race window is small (no observed issue) but the API
contract is to set platform_data before registering.

Fix: hoist the assignment above the register call, or stuff the led
back-pointer in `dev_set_drvdata(led_cdev->dev, led)` under the
classdev's own state lock.

Routing: **ASK-edit** in `leds-lp5812.c`.

### C7. UAPI struct alignment audit [P2 ABI]

`include/uapi/linux/fmd/Peripherals/fm_pcd_ioctls.h` carries several
structs with `uint8_t` followed by `uint64_t` without explicit padding.
On arm64, alignment is enforced and the compiler inserts 7 bytes of
hole — `sizeof(struct)` is what userspace will compute too **as long as
it builds with the same alignment rules**, but a userspace built with
`-fpack-struct` (non-default) would mis-compute. ABI-by-convention.

Fix: explicit `__attribute__((aligned(8)))` or explicit padding fields.
Lower priority; flag for the next UAPI refresh.

Routing: **policy** — document in the UAPI README.

---

## Cross-cutting recommendations

1. **Run `scripts/audit-locks.sh`** (proposed in B7) and triage any
   sleeping-in-spinlock hits as they emerge. Combined with
   `CONFIG_DEBUG_ATOMIC_SLEEP=y`, the kernel will catch most of these
   at boot — but only on code paths that actually run; the audit
   surfaces the ones that don't run on boot but do under config-load
   stress.
2. **Run `scripts/check-uapi-sizes.sh`** (proposed in B5) before every
   ask tag. Hashes every `struct ioc_fm_pcd_*` size, fails on drift
   without manifest entry.
3. **Audit `ASSERT_COND` uses on user-input** (A2). Add a
   `scripts/audit-assert-cond.sh` that greps `ASSERT_COND` and reports
   any whose argument references a parameter named `*from_user*` or
   immediately precedes a `copy_from_user` call.
4. **Adopt `__must_check`** on the kernel-API function signatures in
   `include/linux/fsl_{bman,qman}.h` for functions that allocate
   resources (e.g., `bman_pool_new`, `qman_create_fq`,
   `qman_create_cgr`). The ABI is exported, but `__must_check` is
   non-ABI and will catch missed checks in OOT consumers (cdx OOT
   module, other modules).

## Out of scope

- Full conversion of NCSW (NetCommSW abstraction layer) `t_*` typedefs
  to plain `struct *` is a multi-asks effort with no immediate
  defensive payoff.
- Fully rewriting `fm_cc.c` allocation paths to RCU is rejected — the
  upstream is dead and the code is legacy; localized lock fixes are
  the right granularity.
- Conversion to the mainline FMan/DPAA component framework is
  explicitly forbidden by `.clinerules/20-sdk-driver-rules.md`.

---

## Suggested ask-iteration sequencing

To keep CI cycle time bounded (each ask = ~22 min ARM64 build), batch
defects rather than one-per-tag:

| Tag | Items | Rationale |
|---|---|---|
| ask27 | A1, A2, A3 | All P0 user-boundary; touches qbman + sdk_fman wrappers; one logical fix-class. |
| ask28 | A4, A5, B6 | DPAA Rx/Tx error-unwind hardening, isolated to `dpaa_eth_sg.c`. |
| ask29 | B1, B2, B3 | sdk_fman lock-leak + class_create + qman uninitialized stack — independent files. |
| ask30 | C1, C2, C3 | NAPI Rx perf nudges + `__read_mostly`. Roll up after CI bake. |
| ask31+ | B4, B5, B7, B8, C4..C7 | UAPI/ABI hardening + DTSI + misc, slower-cadence. |

Each ask must run `scripts/patch-health.sh --source release` to
confirm `Pass`/`Fail`/SDK-conflict/`266 files` invariants hold, plus
the new `ASK-edit` grep to enumerate every direct-edit delta.