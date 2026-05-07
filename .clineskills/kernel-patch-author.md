# Skill: kernel-patch-author

Authoring a new kernel patch for the `kernel-ls1046a-build` producer repo, end-to-end, while staying inside the invariants defined in `.clinerules/{10-patch-authoring,20-sdk-driver-rules,30-kconfig-defconfig,50-thresholds-are-authoritative,60-tooling-paths}.md`.

## When to use

A change to the Linux 6.6.137 source tree must be persisted as a patch. Use this skill whenever you are creating or substantively modifying a file in `release/patches/{vyos,ask,fixes}/`.

Do NOT use this skill for:
- Defconfig changes (those go in `release/vyos-base/*.config` or `release/ask.config` — see `.clinerules/30-kconfig-defconfig.md`).
- Verbatim NXP SDK source drops (those go under `release/patches/kernel/sdk-sources/<mirrored-path>` — use the `sdk-source-drop` skill instead).

## Inputs the agent must collect first

| Input | Example |
|---|---|
| **Bucket** | `vyos` / `ask` / `fixes` |
| **Short slug** | `bridge-add-promisc-counter` |
| **Target file(s) in kernel tree** | `net/bridge/br_input.c` |
| **One-line summary** | "ASK: count promisc-mode hits in bridge fast-path" |
| **Commit-message body** | Why; references; failure mode it fixes |

If any are missing, ask the user with `ask_followup_question`. Do NOT guess the bucket — the bucket determines numbering range and apply order.

## Numbering rules (from `.clinerules/10`)

| Bucket | Range | Next free number = |
|---|---|---|
| `vyos/` | `001..009` | `max(prefix in release/patches/vyos/) + 1`, zero-padded to 3 |
| `ask/` | `010..080` (multiples of 10 are reserved for new fast-paths) | next unused 3-digit prefix |
| `fixes/` | `090+` | `max(prefix in release/patches/fixes/) + 1` |

Never renumber existing patches. Never re-use a prefix.

## Procedure

```bash
# 0. Sanity: clean tree, fresh kernel
git status --porcelain   # must be empty (or only your new patch staged)
rm -rf work/linux-6.6.137
tar -xf work/linux-6.6.137.tar.xz -C work/

# 1. Apply EVERY existing patch in canonical order, in-tree
( cd work/linux-6.6.137 && git init -q && git add -A && git commit -qm pristine )
for p in release/patches/vyos/*.patch \
         release/patches/ask/*.patch \
         release/patches/fixes/*.patch ; do
    patch -p1 -d work/linux-6.6.137 < "$p" || { echo "BAILING at $p"; exit 1; }
done
# (SDK source drops are NOT applied here; they're a separate copy step
#  owned by scripts/apply-to-tree.sh. See .clinerules/20.)

# 2. Edit target files in work/linux-6.6.137/
$EDITOR work/linux-6.6.137/<target-file>

# 3. Generate the diff and normalize it
( cd work/linux-6.6.137 && git diff --no-prefix -- <target-file...> ) \
  | awk -f scripts/normalize-patch.awk \
  > release/patches/<bucket>/<NNN>-<short-slug>.patch

# 4. Add a leader (subject + rationale) at the top of the .patch file:
#    one Subject: line, one blank, the body explaining motivation,
#    then the diff. Keep < 72 cols.
$EDITOR release/patches/<bucket>/<NNN>-<short-slug>.patch

# 5. Verify (mandatory loop)
rm -rf work/linux-6.6.137 && tar -xf work/linux-6.6.137.tar.xz -C work/
bash scripts/patch-health.sh --source release
# Required output:
#   Pass: 13   Fail: 0
#   0 SDK conflicts
#   264 files to install

# 6. Visual hunk verification — defeat silent truncation (ask13 → ask14)
patch -p1 -d work/linux-6.6.137 < release/patches/<bucket>/<NNN>-<short-slug>.patch
grep -n '<expected-content-after-patch>' work/linux-6.6.137/<target-file>

# 7. Run hunk validator (post-edit hook also runs this automatically)
.clinehooks/patch-hunk-validator.sh release/patches/<bucket>/<NNN>-<short-slug>.patch

# 8. Stage & commit with the right prefix (.clinerules/40)
git add release/patches/<bucket>/<NNN>-<short-slug>.patch
git commit -m "<bucket>: <one-line summary>"
```

If the new patch adds a persistent patch (raises the `Pass:` count), update the `Pass: 13` invariant in `.clinerules/50-thresholds-are-authoritative.md` in the SAME commit (or a `docs:` commit on top of it), with a note explaining why.

## Hunk-header arithmetic checklist

For every `@@ -a,b +c,d @@` you author or edit:

- `b` == count of body lines beginning with ` ` (context) or `-`.
- `d` == count of body lines beginning with ` ` (context) or `+`.
- For pure-additions (new file): header is `@@ -0,0 +1,N @@` and `N` must equal the exact `+`-line count.

The `patch-hunk-validator` hook in `.clinehooks/` flags mismatches; treat any warning as P0 before tagging.

## Output contract

A successfully authored patch satisfies ALL of:

1. Lives under `release/patches/<bucket>/<NNN>-<slug>.patch` with monotonically next prefix.
2. `scripts/patch-health.sh --source release` reports `Pass: 13  Fail: 0`, `0 SDK conflicts`, `264 files to install` (or the new agreed-upon thresholds, called out explicitly in the commit body).
3. `.clinehooks/patch-hunk-validator.sh` reports zero issues for the new file.
4. Visual `grep` confirms post-patch content is present in `work/linux-6.6.137/<target-file>`.
5. Commit message uses the correct prefix (`ask:|vyos:|fixes:|sdk:|...`) and contains one logical change.
6. NO branch push has occurred for a `kernel-*` tag iteration (see `.clinerules/00`).