# Workflow: Diagnose an On-Device ASK Failure

When the consumer team reports that Mono is unhealthy, route the symptom to
the right repo before doing any work. This avoids wasting an ARM64 CI cycle
in this producer when the cause lives in `vyos-ls1046a-build` (or vice
versa).

## 0. Symptom intake

Ask for / collect:

1. The exact failed lines from `ask-check` on the device.
2. `dmesg | grep -iE 'ASK|fci|cmm|fman|dpaa|cdx|panic'`
3. `zcat /proc/config.gz | grep -E 'NET_KEY|ASK_FCI_NLKEY|INET_IPSEC_OFFLOAD|FSL_SDK'`
4. `cat /proc/net/netlink | awk '{print $2}' | sort -u`
5. `uname -r` and the consumer ISO build tag.

## 1. Two-chain triage

| Chain-1 (this repo) | Chain-2 (consumer) |
|---|---|
| `cmm process running [FAILED]`<br>`cmm.service active [FAILED]`<br>`cmmCtInit:NNNN fci_open() failed, Protocol not supported`<br>missing proto 32 in `/proc/net/netlink` | `dpa_app applied PCD configuration (failed rc=65280)`<br>`BMan fragment buffer pool located by CDX [FAILED]`<br>`fm_cc.c:NNNN AllocStatsObjs Memory Allocation Failed`<br>`no ASK driver probe/init/bind failures (≥1 hit(s))` |
| **Routes to:** `kernel-ls1046a-build` (this repo) | **Routes to:** `vyos-ls1046a-build` (consumer) |
| Fix surface: defconfig fragment, `fixes/` patch, or SDK drop | Fix surface: rebuild `fmc` with `external`/`aging` support, or trim `cdx_pcd.xml` budget |

The chains are independent. A single device may show both, but each gets
fixed in its own repo.

## 2. Chain-1 deep checks (if this repo is responsible)

```bash
# Required on-device output for diagnosis
zcat /proc/config.gz | grep -E 'NET_KEY|ASK_FCI_NLKEY|INET_IPSEC_OFFLOAD'
cat /proc/net/netlink | awk '{print $2}' | sort -u  # must include 32
grep ask_fci /proc/kallsyms                          # must be non-empty
ls /sys/module/ask_fci_nlkey 2>/dev/null             # must exist if =y
dmesg | grep 'ASK FCI'
```

Reference invariants (must all hold):

| Symbol | Required | Why |
|---|---|---|
| `CONFIG_NET_KEY` | `=y` | Otherwise `obj-y` items in `net/key/Makefile` are silently dropped (kbuild trap). |
| `CONFIG_ASK_FCI_NLKEY` | `=y` | Registers `NETLINK_KEY=32` via `late_initcall`. |
| `CONFIG_INET_IPSEC_OFFLOAD` | `=n` | Re-enabling fails to build on 6.6 (xfrm_state lacks `curr_time`/`offloaded`). |
| `CONFIG_FSL_SDK_FMAN` | `=y` | NXP SDK FMan, not mainline. |
| `CONFIG_FSL_SDK_DPAA_ETH` | `=y` | NXP SDK DPAA ETH, not mainline. |
| `CONFIG_FSL_SDK_DPA` | `=y` | NXP SDK QBMan, not mainline. |

If any are wrong, the fix is in `release/vyos-base/*.config` or
`release/ask.config`. Author per `.clineworkflows/cut-ask-release.md` step 1a.

## 3. Chain-2 deep checks (if consumer is responsible)

This repo cannot fix Chain-2. Capture the evidence and hand it off to
`vyos-ls1046a-build`. The producer-side action is:

- Confirm `dmesg` shows `fm_cc.c:.*AllocStatsObjs Memory Allocation Failed`.
- Confirm `fmc -a` on the device prints `WARN: Unknown attribute 'external'`
  / `WARN: Unknown attribute 'aging'`.
- File / update an issue against `vyos-ls1046a-build` with that evidence and
  reference `FIX-PLAN-ASK-PCD.md` Problem A.

Do **not** open a producer-side issue or release a new askN for Chain-2
symptoms.

## 4. Reproducing locally

For Chain-1 only (Chain-2 needs real DPAA hardware):

```bash
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
bash scripts/apply-to-tree.sh
# inspect the merged config
( cd work/linux-6.6.137 && make ARCH=arm64 olddefconfig )
grep -E 'NET_KEY|ASK_FCI_NLKEY' work/linux-6.6.137/.config
```

If the `.config` lines do not match the expected values, your defconfig
fragment edit did not take effect — check fragment ordering (lexical) and
that the symbol is not being unset later in the merge.

## 5. Authoring the fix

Drop into `.clineworkflows/cut-ask-release.md` from step 1, with the bucket
chosen as:

- defconfig symbol problem → `vyos:` commit on `release/vyos-base/*.config`
  or `ask:` commit on `release/ask.config`
- 6.6.y kernel API drift / missing UAPI → `fixes:` patch (numbering 090+)
- ASK fast-path code change → `ask:` patch (numbering 010..080)

## 6. Capture the lesson

After resolving a Chain-1 issue:

1. Update the relevant `FIX-PLAN-*.md` to mark RESOLVED-in-askN.
2. If the bug was due to a kbuild / build-system trap that could recur, add
   a paragraph to `.clinerules/` (most likely `30-kconfig-defconfig.md` or a
   new rule) and / or `AGENTS.md` "Reference-Aligned Defconfig Invariants".
3. Optionally store the insight via the `qdrant` MCP server's `qdrant-store`
   tool under the `agent_memory` collection so future sessions inherit it.

## Anti-patterns

- Releasing a new askN to "test" a Chain-2 hypothesis. Costs ~22 min ARM64
  CI and won't change anything.
- Asking the user to gather Chain-2 evidence on the device when the symptom
  is clearly Chain-1 (or vice versa).
- Editing `.config` directly in `work/linux-6.6.137/` — it gets overwritten
  by `apply-to-tree.sh` / `olddefconfig`.