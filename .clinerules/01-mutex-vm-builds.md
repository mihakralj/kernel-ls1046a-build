# Rule: Producer and Consumer Builds Are Mutually Exclusive

The producer (`lts_6.6_ls1046a` → `.github/workflows/build-and-release.yml`) and the consumer (`vyos-ls1046a-build` → `.github/workflows/self-hosted-build.yml`) **share a single Azure ARM64 self-hosted runner VM**. Both workflows wrap their build job between a `start-vm` step (deallocated → running) and a `stop-vm` step (running → deallocated). The VM cannot be in two states at once.

## Hard rule

**Never have producer and consumer builds in flight simultaneously.** Always wait for one to reach a terminal state (`success`, `failure`, or `cancelled`) before dispatching or pushing a tag/branch that fires the other.

## What goes wrong if you ignore this

The two workflows race for the same VM:

| Sequence | Effect |
|---|---|
| Run A's `stop-vm` fires while Run B's job is mid-build | B's runner abruptly disconnects → B fails with "The operation was canceled" or "Lost connection to the runner" partway through |
| Run B's `start-vm` fires while Run A is still running | `az vm start` is a no-op (already running), but B's job races A on the same SSH/runner-token state and one of them wins/loses unpredictably |
| Both `stop-vm` steps fire near each other | One tries to deallocate a VM whose runner is still draining → orphaned runner registration on the VM at next boot |

The classic symptom is the canceled-at-1-to-2-minute "Build … in progress / canceled" pattern with no useful log content (the runner never got far enough to fail in a meaningful way). Confirmed in production 2026-05-06: producer branch-push run cancelled at 1m12s while a consumer ISO build was in progress on the same VM.

## Pre-dispatch checklist

Before any of:

- `git push origin <branch>` on `lts-6.6-ls1046a` / `main` (consumer)
- `git push origin kernel-6.6.137-ask<N>` (producer tag)
- `gh workflow run self-hosted-build.yml -R mihakralj/vyos-ls1046a-build`
- `gh run rerun <id>` for either workflow

Run **both** of these and require an empty / completed-only result:

```bash
gh run list --workflow=build-and-release.yml -R mihakralj/lts_6.6_ls1046a --limit 5
gh run list --workflow=self-hosted-build.yml -R mihakralj/vyos-ls1046a-build --limit 5
```

If either lists a run with status `queued` or `in_progress`, **wait** (or cancel that run intentionally with `gh run cancel <id>`) before proceeding.

## Why a `concurrency:` group cannot save us

Each repo has its own `concurrency:` group inside its own workflow file (`group: build-and-release` on producer, `group: self-hosted` on consumer). GitHub's concurrency primitive scopes to a single workflow within a single repo; it has no notion of "this VM is shared with workflow X in repo Y". Cross-repo / cross-workflow mutual exclusion has to be enforced **manually by the operator**.

## Sequencing patterns

| You want to … | Do this |
|---|---|
| Cut a new ask tag AND verify the resulting ISO | (1) tag-push producer, (2) wait for producer green, (3) bump consumer pin, (4) push consumer / dispatch ISO build, (5) wait for consumer green |
| Re-run a producer build that got cancelled by VM contention | First confirm there is no in-flight consumer build, then `gh run rerun <producer-id>` |
| Re-run a consumer build | First confirm no in-flight producer build, then `gh workflow run self-hosted-build.yml -R mihakralj/vyos-ls1046a-build` |
| Push a doc-only / scripts-only commit on the producer branch | Same rule applies — the safety-net branch CI still spins the VM. Squash trivial doc commits or push them while the consumer is idle |

## Forbidden

1. Pushing a producer tag (`kernel-6.6.137-ask*`) while a consumer ISO build is `in_progress`.
2. Dispatching a consumer ISO build while a producer build is `queued` or `in_progress`.
3. Pushing the producer branch ref (which fires the safety-net build) without first checking the consumer queue.
4. Adding a `workflow_dispatch:` trigger to either workflow that bypasses the operator-visible queue (the consumer's `auto-build.yml` is reusable-only by design — see consumer `AGENTS.md`).