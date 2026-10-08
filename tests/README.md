# Tests

The Pester v5 suite is in `StackSupervisor.Tests.ps1`. Run it with
`.\Invoke-Tests.ps1`; it uses fixtures and mocks, plus a loopback socket for the probe
protocol. It does not require a gateway service or external endpoint.

## Why it matters more than usual here

Every failure mode in `../docs/LESSONS.md` was discovered in production, and several of
them are plain logic bugs that a unit test would have caught in milliseconds:

- an object matcher that picked a nested reference instead of the real endpoint block;
- a detection filter that matched its own command line;
- a candidate ranking built on a single noisy sample;
- a deferred recovery that assumed another component was alive.

None of those need a live service to reproduce. They need a fixture file, a stub process
and an assertion.

## Harness

`Invoke-Tests.ps1` runs [Pester](https://pester.dev) v5 when it is installed and exits with
a clear message when it is not. Tests are self-contained and run on a clean Windows host
without a gateway service present:

| Layer | How it should be exercised |
|---|---|
| JSON block discovery | Fixture JSON, including an earlier nested tag reference, escaped strings, duplicate keys and ambiguous endpoint objects. |
| Patch rules and read-back validation | Temporary fixture files; assert exact path updates, preservation of similarly named nested fields, backup creation and selected-path validation. Legacy regex rules must be unique. |
| Health scoring | Mock the probe function (Pester `Mock`) and drive the score table 2 / 1 / 0. |
| Failover decision logic | Mock catalog fetch and candidate measurement; assert that no configuration write occurs when no candidate beats the active score. |
| Keeper component detection | Synthetic process-list objects; assert the self-match exclusion. |
| Probe protocol | A loopback TCP listener sends a canned CONNECT header followed by more than 1 KiB of buffered bytes; assert the reader leaves all bytes after the header available. |

## Current state

The suite also covers process identity for restart: a same-name process using another
configuration is ignored, and restart refuses to stop when it cannot identify one unique
configured instance.
