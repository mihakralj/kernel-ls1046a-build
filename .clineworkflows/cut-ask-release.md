# Workflow: Cut a `kernel-6.6.135-askN` Release

End-to-end workflow for shipping a new ASK kernel iteration from this producer
repo. Follow in order. Do not skip steps. The whole loop costs ~22 min of
GitHub-hosted ARM64 CI per tag, so getting it right the first time matters.

## 0. Preconditions

- You are on `lts-6.6-ls1046a` with a clean working tree (`git status` empty).
- You know the next askN number (the one you will tag). Never reuse an askN.
- You know which bucket your change belongs to (`vyos/`, `ask/`, or `fixes/`)
  and whether it is a patch edit, a defconfig edit, an SDK refresh, or a
  combination.

## 1. Author the change

Pick the route that matches your change:

### 1a. Defconfig fragment (preferred for symbol toggles)
- Edit the appropriate file under `release/vyos-base/` or `release/ask.config`.
- **Never** carry a symbol toggle inside a `*.patch`.

### 1b. Patch in `release/patches/<bucket>/`
- Re-extract a pristine kernel tree:
  ```bash
  rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/
  ```
- Apply existing patches up to the insertion point with `patch -p1`.
- Edit files in `work/linux-6.6.135/`.
- Generate the patch:
  ```bash
  ( cd work/linux-6.6.135 && git diff --no-prefix ) \
    | awk -f scripts/normalize-patch.awk \
    > release/patches/<bucket>/NNN-name.patch
  ```
- Numbering ranges: `vyos/` 001..009, `ask/` 010..080, `fixes/` 090+.

### 1c. SDK source refresh (`release/patches/kernel/sdk-sources/`)
- Drop the new files in mirrored paths.
- Update the expected `266 files to install` count if it changes — and call
  it out in the commit body.

## 2. Validate (mandatory, every iteration)

```bash
rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/
bash scripts/patch-health.sh --source release
```

Required output:
```
Pass: 15   Fail: 0
0 SDK conflicts (266 files to install)
```

A clean `patch-health` is **necessary but not sufficient** — `git apply` can
silently truncate added lines if a hunk header's `NewCount` is wrong. Visually
verify the affected file(s):

```bash
patch -p1 -d work/linux-6.6.135 < release/patches/<bucket>/<patch>
grep -n '<expected-content>' work/linux-6.6.135/<patched-file>
```

If your change touched defconfig fragments, also surface the diff:

```bash
bash scripts/diff-vyos-config.sh
```

If anything fails, **fix the cause, never the threshold**
(see `.clinerules/50-thresholds-are-authoritative.md`).

## 3. Commit

One logical change per commit. Subject prefix from the matrix in
`.clinerules/40-commit-style.md`:

| Scope | Prefix |
|---|---|
| `release/patches/ask/` | `ask:` |
| `release/patches/vyos/`, `release/vyos-base/` | `vyos:` |
| `release/patches/fixes/` | `fixes:` |
| `release/patches/kernel/sdk-sources/` | `sdk:` |
| `scripts/` | `scripts:` |
| `.github/workflows/` | `ci:` |
| Markdown / `.clinerules/` | `docs:` |
| `release/manifest.json` askN bump | `release:` |

Body should include the `patch-health` result line and any defconfig diff.

## 4. Bump the manifest

Edit `release/manifest.json` and bump the askN field. Commit as `release:`.

## 5. Tag and push (TAG ONLY)

```bash
git tag kernel-6.6.135-askN
git push origin kernel-6.6.135-askN
```

**Forbidden** in the same `git push`:
- the branch ref `lts-6.6-ls1046a`
- `--follow-tags`
- two distinct `kernel-*` tags

The pre-push git hook (`.clinehooks/block-dual-ref-push.sh`) will reject these.

## 6. Watch CI

```bash
gh run list --workflow=build-and-release.yml --limit 5
gh run watch <run-id>          # streams; or
gh run view <run-id> --log-failed
```

Native ARM64 build runs ~22 min. Tag pushes publish a GitHub Release; branch
pushes do not.

## 7. After CI is green

- Verify the release: `gh release view kernel-6.6.135-askN`.
- Update the consumer pin in `vyos-ls1046a-build/data/ask-kernel.pin`
  (separate repo) and rebuild the ISO there.
- If the change resolved an open chain (Chain-1 or Chain-2 in `AGENTS.md`),
  update the corresponding `FIX-PLAN-*.md` to mark it RESOLVED-in-askN.

## 8. After CI is red

- `gh run view <id> --log-failed` and read the actual failure.
- Re-extract pristine tree, re-apply, re-validate locally.
- Bump to ask(N+1) — **never reuse a failed tag**.
- If the failure was a kbuild trap (silent obj-y drop, etc.), capture the
  insight in `.clinerules/` or `AGENTS.md` so it is not relearned.

## Quick reference

```bash
# Local validation loop
rm -rf work/linux-6.6.135 && tar -xf work/linux-6.6.135.tar.xz -C work/
bash scripts/patch-health.sh --source release

# Generate a patch
( cd work/linux-6.6.135 && git diff --no-prefix ) \
  | awk -f scripts/normalize-patch.awk \
  > release/patches/ask/0X0-my-change.patch

# Tag-only release push
git tag kernel-6.6.135-askN && git push origin kernel-6.6.135-askN

# Inspect CI
gh run list --workflow=build-and-release.yml --limit 5
gh run view <id> --log-failed
gh release view kernel-6.6.135-askN