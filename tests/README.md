# Tests

There are no automated tests yet. This directory documents what the suite is expected to
cover and provides the harness it should plug into.

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
a clear message when it is not. Tests are expected to be self-contained and to run on a
clean Windows host without a gateway service present:

| Layer | How it should be exercised |
|---|---|
| JSON block discovery | Fixture files only. No process, no network. |
| Patch rules and read-back validation | Fixture files written to a temporary directory; assert the resulting text and the restore path when validation fails. |
| Health scoring | Mock the probe function (Pester `Mock`) and drive the score table 2 / 1 / 0. |
| Failover decision logic | Mock catalog fetch and candidate measurement; assert *which* endpoint would be written, including the *no better candidate means no write* rule. |
| Keeper component detection | Synthetic process list objects; assert the self-match exclusion. |
| Probe protocol | A loopback TCP listener that speaks a canned CONNECT response; assert header and body handling, including a body larger than the reader buffer. |

## Current state

`Invoke-Tests.ps1` only reports that no test files exist. It is the contract, not the suite.

