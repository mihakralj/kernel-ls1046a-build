# Rule: Thresholds Are Authoritative

The numeric assertions enforced by `scripts/patch-health.sh` and the CI workflow are **invariants of the producer contract**, not knobs.

## Invariants

| Check | Required value | Source |
|---|---|---|
| `patch-health.sh` pass count | `Pass: 17` | `scripts/patch-health.sh --source release` |
| `patch-health.sh` fail count | `Fail: 0` | same |
| SDK conflicts | `0 SDK conflicts` | same |
| SDK files installed | `266 files to install` | `scripts/apply-to-tree.sh` |
| Patch buckets | `vyos/` (3) → `ask/` (8) → `fixes/` (6) | `release/patches/` |

## Hard rules

1. **Never weaken an assertion to make a failing build pass.** If a check fails, fix the cause; do not edit the threshold.
2. The `266 files` count changes only when SDK sources are deliberately re-imported. Such a change requires:
   - A `sdk:` commit explaining the source NXP tag and the file delta (added / removed).
   - The new count called out explicitly in the commit body.
3. The `Pass: 17` count changes only when a new persistent patch is added or one is removed (or absorbed into the SDK source tree under the ask26+ direct-edit policy). Each change is its own commit.
4. If a check is wrong (false positive / negative), fix `patch-health.sh` itself in a `scripts:` commit — not by skipping the check.

## Anti-patterns (forbidden)

- Adding `|| true` to a `patch-health.sh` invocation in CI or scripts.
- Commenting out an assertion "temporarily."
- Lowering the expected pass count to match an unintentional patch deletion.
- Bypassing `apply-to-tree.sh` to skip SDK file count enforcement.