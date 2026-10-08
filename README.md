# stack-supervisor

Layered supervision for a local gateway service whose upstream endpoints are unreliable.

A process that is alive is not the same thing as a service that works. This toolkit
watches the **data path**, scores partial outages instead of treating health as a binary,
re-routes the service to a better upstream endpoint when the current one degrades, and
keeps the supervisor itself alive from the operating system scheduler.

```
                 ┌──────────────────────────────────────────────────────────┐
                 │  StackKeeper  (scheduled task, every 2 minutes)          │
                 │  ensures the service and every supervisor are running     │
                 └───────────────┬──────────────────────────────────────────┘
                                 │ starts / restarts
        ┌────────────────────────▼─────────────────────────┐
        │  StackSupervisor  (resident loop, every 60 s)    │
        │                                                  │
        │   1. probe the data path through the service     │
        │   2. score 2 / 1 / 0 and count consecutive rounds│
        │   3. fetch the endpoint catalog                  │
        │   4. measure candidates in isolated instances    │
        │   5. patch the config, restart, verify           │
        └──────────────────────────────────────────────────┘
```

## Why another watchdog

| Naive supervision | What actually happens in production |
|---|---|
| Poll the process list | The process is up; the upstream is dead and every request times out |
| Health check = "did the request fail?" | The upstream is flapping: one target answers, another does not |
| Restart on failure | Restarting never helps when the endpoint itself is gone |
| Watchdog watches the service | Nothing watches the watchdog |
| Scheduler runs `powershell.exe` | A console window flashes on the desktop every interval |

Each of those rows cost real downtime before it became a design rule. See
[docs/LESSONS.md](docs/LESSONS.md).

## Health model

Every round the supervisor asks the running service to fetch each configured health
target and asserts on the response body - not on the connection succeeding.

| Score | Meaning | Action |
|---|---|---|
| `2/2` | every health target answered as expected | healthy, counters reset |
| `1/2` | exactly one target answered | degraded; switch after `degradedThreshold` consecutive rounds |
| `0/2` | nothing answered | down; switch after `failThreshold` consecutive rounds |

## Failover algorithm

1. Confirm the machine has working network at all (otherwise stay put - the fault is local).
2. Fetch the endpoint catalog and rank candidates (region preference, minus the active one).
3. Start one **isolated instance** of the service per candidate, each on its own port,
   and measure every candidate twice. The live service keeps serving traffic throughout.
4. Rank by probe score, then by the **sum of both rounds** (single samples are noise).
5. Keep only candidates that are **strictly better** than the current score, unless
   `-ForceSwitch` was requested. No improvement means no change.
6. Patch the live configuration, restart the service, verify, and fall through to the
   next candidate if verification fails.

## Safety rules

- Every write is preceded by a timestamped backup (last 10 kept).
- The patched file is re-parsed and the changed fields are read back before it is written.
- A cooldown window prevents flapping between candidates.
- `-DryRun` measures everything and writes nothing.
- A missing service is only started by the supervisor when the dedicated process keeper
  has failed to act for `missingThreshold` rounds.

## Quick start

```powershell
# 1. copy and edit the configuration
Copy-Item .\config\supervisor.example.json C:\ProgramData\edge-gateway\supervisor.json
notepad C:\ProgramData\edge-gateway\supervisor.json

# 2. one-shot health check (switches endpoints when unhealthy)
.\src\StackSupervisor.ps1 -ConfigPath C:\ProgramData\edge-gateway\supervisor.json -Once

# 3. measure candidates without writing anything
.\src\StackSupervisor.ps1 -ConfigPath C:\ProgramData\edge-gateway\supervisor.json -Once -ForceSwitch -DryRun

# 4. register the keeper that keeps everything alive from the task scheduler
.\install\Install-Keeper.ps1 -ConfigPath C:\ProgramData\edge-gateway\supervisor.json -IntervalMinutes 2
```

## Layout

```
src/StackSupervisor.ps1        health scoring, candidate measurement, failover
src/StackKeeper.ps1            component keep-alive, launched by the scheduler
install/Install-Keeper.ps1     registers / removes the scheduled task
install/Invoke-Hidden.vbs      template for the no-flash launcher
config/supervisor.example.json annotated configuration
docs/DESIGN.md                 architecture and failure-mode analysis
docs/LESSONS.md                incidents that shaped the design
```

## Requirements

Windows 10/11 with Windows PowerShell 5.1 or PowerShell 7. No external modules.
Everything runs as the signed-in user; the only privileged action is an optional
scheduled-task registration for all users.

## Operations

```powershell
schtasks /query /tn StackKeeper      # next run time and last result
schtasks /run   /tn StackKeeper      # force a keep-alive pass
Get-Content C:\ProgramData\edge-gateway\supervisor.log -Tail 40
Get-Content C:\ProgramData\edge-gateway\keeper.log     -Tail 20
```

The supervisor is safe to run while the resident instance is active: a named mutex makes
the second instance exit immediately instead of fighting over the configuration file.

## Status and limitations

This is a working tool, not a finished one. `docs/LIMITATIONS.md` lists - bluntly - the
parts the author is least confident about, including several High severity concerns in the
configuration patching and service restart paths. `tests/` describes the test suite the
project needs but does not have yet, and `CONTRIBUTING.md` explains how to help.

If you are reviewing this project: start with the limitations list, then the incidents in
`docs/LESSONS.md`. Both are written to be attacked.

## License


MIT - see [LICENSE](LICENSE).
