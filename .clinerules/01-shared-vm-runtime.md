# Rule: Shared Cobalt 100 VM Runtime (A+B Pattern)

The producer (`kernel-ls1046a-build` → `.github/workflows/build-and-release.yml`) and the consumer (`vyos-ls1046a-build` → `.github/workflows/self-hosted-build.yml`) share **one** Azure ARM64 Cobalt 100 VM. The cost / coordination problem is solved by two cooperating mechanisms — there is no operator-side mutex.

## Pattern A — Idle-deallocator on the VM (NOT in CI)

Workflows only ever call `az vm start` (idempotent — no-op if the VM is already running). Workflows **never** call `az vm deallocate`. A systemd timer on the VM watches for runner idleness and self-deallocates after the idle threshold.

### What lives on the VM

`/usr/local/sbin/idle-deallocate.sh`:

```bash
#!/bin/bash
set -euo pipefail
IDLE_THRESHOLD_SEC="${IDLE_THRESHOLD_SEC:-600}"   # 10 min default
STATE=/var/lib/idle-deallocate.last-busy

# Busy if either runner has an active job
if pgrep -f 'Runner.Worker' >/dev/null; then
  date +%s > "$STATE"
  exit 0
fi
last_busy=$(cat "$STATE" 2>/dev/null || echo 0)
now=$(date +%s)
if (( now - last_busy < IDLE_THRESHOLD_SEC )); then
  exit 0
fi

# Self-deallocate via Managed Identity
az login --identity --allow-no-subscriptions >/dev/null
META=$(curl -sH Metadata:true \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01')
SUB=$(jq -r .compute.subscriptionId   <<<"$META")
RG=$(jq -r .compute.resourceGroupName <<<"$META")
NAME=$(jq -r .compute.name            <<<"$META")
az vm deallocate --ids \
  "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/$NAME"
```

`/etc/systemd/system/idle-deallocate.service`:

```ini
[Unit]
Description=Self-deallocate Azure VM after runner idle threshold

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/idle-deallocate.sh
```

`/etc/systemd/system/idle-deallocate.timer`:

```ini
[Unit]
Description=Run idle-deallocate every 2 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=2min
Unit=idle-deallocate.service

[Install]
WantedBy=timers.target
```

Enable: `systemctl enable --now idle-deallocate.timer`.

### Required Azure plumbing

- VM has **System-assigned Managed Identity** enabled.
- That identity is granted role **`Virtual Machine Contributor`** scoped to the VM resource (`/subscriptions/.../resourceGroups/arm64-runner-group/providers/Microsoft.Compute/virtualMachines/arm64-runner`). Do not grant subscription-scope; least privilege.
- VM has `azure-cli`, `jq`, `curl` installed (`apt-get install -y azure-cli jq curl`).

## Pattern B — Two registered runners on the same VM

Two `actions-runner` services run on the VM, each with its own work directory and unique name. GitHub schedules producer and consumer to *different* runners, so they execute in parallel on the shared cores.

| Runner name | Repo it serves | Labels | Install dir | systemd unit |
|---|---|---|---|---|
| `lts-build-runner` | `kernel-ls1046a-build` | `self-hosted, Linux, ARM64` (matches producer's `runs-on: self-hosted`) | `/home/vyos/actions-runner-lts/` | `actions.runner.mihakralj-kernel-ls1046a-build.lts-build-runner.service` |
| `arm64-runner` | `vyos-ls1046a-build` | `self-hosted, Linux, ARM64` (matches consumer's `runs-on: ARM64`) | `/home/vyos/actions-runner/` | `actions.runner.mihakralj-vyos-ls1046a-build.arm64-runner.service` |

Both runners run as systemd services owned by user `vyos`. Their `_work` directories live inside their respective install dirs (`/home/vyos/actions-runner-lts/_work/`, `/home/vyos/actions-runner/_work/`) and are therefore already runner-namespaced.

### Build-script invariants under B

- Per-build state must namespace by runner. The producer's build scripts use the standard `${GITHUB_WORKSPACE}` (already runner-local under `_work/<repo>/<repo>`), so kernel extract dirs (`work/linux-6.6.137`), ccache (`~/.ccache`), and apt locks live inside the workspace and never collide.
- If a future build script wants a fixed absolute path (e.g. `/build/cache/...`), it MUST embed `${RUNNER_NAME}` in the path or live under `${GITHUB_WORKSPACE}`. Adding such a path without namespacing will reintroduce the contention problem.
- Don't read or write `/var/lib/idle-deallocate.last-busy` from build steps — that's the daemon's contract surface.

## Why this is correct

- **No CI step ever calls `az vm deallocate`** → workflows cannot kill each other's runners.
- **`az vm start` is idempotent** → both workflows can race to call it; whichever lands first wins, the other no-ops in <1s.
- **Two runners → two parallel build slots** on the same VM. GitHub's runner scheduler picks an idle one per job; ordering is automatic.
- **Idle-deallocator runs every 2 min, threshold 10 min** → during a burst of back-to-back builds the VM never powers down; ~10 min after the last `Runner.Worker` exits, the VM deallocates. Standing cost ≤ ~$0.20/day on Cobalt 100.

## Failure modes and operator response

| Symptom | Likely cause | Action |
|---|---|---|
| Both runners offline; first job after a long idle takes >2 min before the build container appears | VM cold-starting from deallocated; expected. | Wait. The `Wait for self-hosted runner` step polls for up to 5 min. |
| One runner stuck `offline` while the other is `online` | Crashed `actions.runner.*.service` on that runner | SSH to VM: `systemctl restart actions.runner.<repo>.<name>` |
| VM never deallocates despite no builds for >10 min | Idle-deallocator timer disabled or `az login --identity` failing (Managed Identity / role missing) | `journalctl -u idle-deallocate.service -n 50` on the VM |
| `az vm deallocate` succeeds while a build is mid-flight | A workflow has been re-edited to call `az vm deallocate` (regression) | Revert the offending workflow change. CI **must not** call deallocate. |
| Two builds collide on a fixed disk path | New build script introduced a non-namespaced absolute path | Namespace the path on `${RUNNER_NAME}` or move it under `${GITHUB_WORKSPACE}` |

## Forbidden

1. Adding any `az vm deallocate` / `azure/login@v3` + stop-step pair to either workflow. The stop is the daemon's job.
2. Per-build polling that *blocks* on the other repo's builds finishing. The whole point of B is that they don't have to.
3. Hard-coding `/build/...` or `/work/...` paths in build scripts without `${RUNNER_NAME}` segregation.
4. Removing one of the two registered runners from the VM (collapses B back to serialized execution).
5. Running the idle-deallocator with a threshold below 5 minutes (risks deallocating between two back-to-back jobs that haven't yet been picked up by the runner).

## Migration history

This rule replaces the earlier `01-mutex-vm-builds.md` (operator-enforced "never run producer + consumer together"), which has been retired. The mutex rule was a workaround for the now-removed CI-side `stop-vm` step; with stop responsibility moved onto the VM and two runners registered, mutual exclusion is no longer required.