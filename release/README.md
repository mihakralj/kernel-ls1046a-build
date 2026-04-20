# release/ — committed last-known-good ASK 6.6 artefacts

This directory is **managed by scripts/publish-release.sh**. Do not edit by hand.

## Contents

| Path | Purpose |
|---|---|
| `patches/kernel/003-ask-kernel-hooks.patch` | monolithic kernel patch (feeds build) |
| `patches/kernel/sdk-sources/` | SDK source files to drop into the kernel tree |
| `ask.config` | kernel config fragment |
| `manifest.json` | provenance: which reference/upstream SHAs produced these artefacts |

## How to update

```bash
./scripts/run-pipeline.sh --publish    # runs the full pipeline and promotes
# or, manually after inspecting work/derived/:
./scripts/publish-release.sh
```

`publish-release.sh` refuses to run unless `work/derived/manifest.json::status == "ok"`
(i.e. no reconciliation bundles pending). Use `--force` only if you know what
you're doing.

## How consumers use it

`patch-health.sh` and any downstream kernel build prefer, in order:
1. `work/derived/` (freshly derived, when present)
2. `release/`      (committed last-known-good — this directory)
3. `work/reference/patches/kernel/` (raw upstream reference, final fallback)

So when all three fetchers report "unchanged" and this directory is present,
no network or derivation work is needed — `release/` already holds the answer.
