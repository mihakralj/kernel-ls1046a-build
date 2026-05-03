# Skill: bisect-hunk-truncation

Diagnose and isolate the **silent hunk-truncation** failure mode that produced the ask13 → ask14 regression in this repo:

> A `*.patch` under `release/patches/**/` had `@@ -25,3 +25,6 @@` while the body contained 12 added lines. `git apply` accepted the header, applied only 6 lines, and silently dropped `obj-$(CONFIG_FSL_SDK_FMAN) += sdk_fman/` and `obj-$(CONFIG_FSL_SDK_DPAA_ETH) += sdk_dpaa/` from `drivers/net/ethernet/freescale/Makefile`. `patch-health.sh` reported green; the resulting kernel booted with neither `sdk_fman` nor `sdk_dpaa` initialized.

Use this skill when:

- A producer build is green but the resulting kernel misbehaves at runtime / boot.
- `patch-health.sh` is `Pass: 13  Fail: 0` yet a recently-edited patch is suspect.
- You need to audit the entire patch set after a manual hunk edit.

## Stage 0 — fast scan with the validator hook

```bash
.clinehooks/patch-hunk-validator.sh
```

Output is one stanza per offending hunk:

```
release/patches/<bucket>/NNN-…patch:<lineno>: hunk header mismatch
   header : @@ -a,b +c,d @@
   declared OldCount=<b> NewCount=<d>
   actual   OldCount=<got_old> NewCount=<got_new>
```

Any output here is a P0 candidate; proceed to stage 1 for each finding.

## Stage 1 — confirm with `git apply --check` and `--numstat`

`git apply` is permissive about hunk-header arithmetic; `--check` plus `--numstat` exposes the ground truth:

```bash
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
( cd work/linux-6.6.137 && git init -q && git add -A && git commit -qm pristine )

# Apply every patch up to (but not including) the suspect one:
for p in $(ls release/patches/{vyos,ask,fixes}/*.patch | sort); do
    [[ "$p" == "$SUSPECT" ]] && break
    git -C work/linux-6.6.137 apply --index "$p"
done

# Apply suspect with --numstat to see what git THINKS it changed:
git -C work/linux-6.6.137 apply --numstat "$SUSPECT"

# Cross-check: count actual +/- lines in the patch body:
awk '
  /^@@ / { in_hunk=1; next }
  in_hunk && /^diff --git |^--- |^\+\+\+ /            { in_hunk=0 }
  in_hunk && /^\+/ && !/^\+\+\+/                       { add++ }
  in_hunk && /^-/  && !/^---/                          { del++ }
  END { printf "raw body: +%d -%d\n", add, del }
' "$SUSPECT"
```

A discrepancy between `git apply --numstat`'s `added`/`removed` columns and the raw body counts is the smoking gun.

## Stage 2 — observe the truncation directly

```bash
# Reset, apply ONLY the suspect, then diff applied tree vs raw patch
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
patch -p1 -d work/linux-6.6.137 < "$SUSPECT"

# For each touched file, list the lines the patch SAID it would add:
grep -E '^\+[^+]' "$SUSPECT" | sed 's/^+//'

# And confirm presence in the tree:
grep -nF '<expected-line>' work/linux-6.6.137/<target-file>
```

Any "expected line" that doesn't appear in the tree is a confirmed truncation.

## Stage 3 — repair the hunk header

Recompute counts on the body of the offending hunk:

```
@@ -OldStart,OldCount +NewStart,NewCount @@
        |       |        |       |
        |       |        |       └─ count of body lines starting with ' ' or '+'
        |       |        └─ unchanged: starting offset in the post-image
        |       └─ count of body lines starting with ' ' or '-'
        └─ unchanged: starting offset in the pre-image
```

Edit only the header. **Do not** add or remove body lines to "match" the wrong header — that flips the bug into a real content corruption. After repair:

```bash
.clinehooks/patch-hunk-validator.sh "$SUSPECT"           # zero issues
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
bash scripts/patch-health.sh --source release            # Pass:13 Fail:0
patch -p1 -d work/linux-6.6.137 < "$SUSPECT"
grep -n '<expected-content>' work/linux-6.6.137/<file>   # all expected lines present
```

## Stage 4 — git-bisect across asks (if the regression slipped past producer CI)

If you don't yet know which patch broke things, bisect the producer tag history:

```bash
git bisect start
git bisect bad  kernel-6.6.137-ask<bad>
git bisect good kernel-6.6.137-ask<last-known-good>
git bisect run bash -c '
  rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/ &&
  bash scripts/apply-to-tree.sh &&
  grep -q "obj-\$(CONFIG_FSL_SDK_FMAN) += sdk_fman/" \
       work/linux-6.6.137/drivers/net/ethernet/freescale/Makefile
'
```

Replace the `grep` with whatever invariant identifies the truncated content. The bisect drops you on the offending tag; `git diff` against its predecessor pinpoints the patch edit responsible.

## Output contract

A successful bisect-hunk-truncation pass produces:

1. The exact offending `release/patches/<bucket>/NNN-…patch` and line range.
2. Header arithmetic that previously failed and now passes.
3. A clean `.clinehooks/patch-hunk-validator.sh` (zero output).
4. A green `scripts/patch-health.sh --source release` (`Pass: 13 Fail: 0`, `0 SDK conflicts`, `264 files to install`).
5. A `grep` confirmation that every `+`-line from the patch body is present in `work/linux-6.6.137/<target-file>` post-apply.
6. A commit with prefix matching the bucket (`ask:` / `vyos:` / `fixes:`) and a body referencing the truncation symptom and the corrected counts.