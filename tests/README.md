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
a clear message when it is not; it exits 1 when any test, or a whole test file, fails. Tests
are self-contained and need no gateway service. Cmdlets that exist only on Windows are
mocked, and the test file declares a stub `Get-CimInstance` when the host has none, so the
suite also runs on other hosts.

| Layer | How it is exercised |
|---|---|
| JSON block discovery | Fixture JSON, including an earlier nested tag reference, escaped strings, duplicate keys and ambiguous endpoint objects; a table of documents the tokenizer must accept and must reject; the reason reported for a syntax error, no match and an ambiguous match. |
| Patch rules and read-back validation | Temporary fixture files; assert exact path updates, preservation of similarly named nested fields, backup creation, atomic replacement and selected-path validation. A changed file must not be overwritten. Legacy regex rules must be unique. Optional `{attr:}` rules are skipped without needing their path. The read-back must refuse a patch that fixed only the host or only the port. |
| Health scoring | Mock the probe function (Pester `Mock`) and drive the score table 2 / 1 / 0. Candidate availability is the lowest score across measurement rounds. |
| Catalog parsing | A base64 URI catalog accepts `uriPrefix` both with and without the trailing `://`. |
| Failover decision logic | Mock catalog fetch, candidate measurement and restart; assert that nothing is written when no candidate beats the active score, that a refused restart puts the previous bytes back and is not scored, that the success path keeps the new configuration, and that a failover which throws is reported as a failed attempt. |
| Process identity | Mock `Get-CimInstance`; assert which process matches the config path (slash direction does not matter) and the reason given for each outcome. |
| Keeper component detection | Synthetic process-list objects; assert the self-match exclusion. |
| Probe protocol | A loopback TCP listener sends a canned CONNECT header followed by more than 1 KiB of buffered bytes; assert the reader leaves all bytes after the header available. |

## What is not covered

The main loop (it is top-level script code, so the function loader skips it), the probe over
TLS, and real process start and stop. See row 9 of `docs/LIMITATIONS.md`.

## Break your guard once

A guard is only as good as a test that can fail. When you add or change one, break it on
purpose - remove the check, or weaken it to the old behaviour - and confirm that a test goes
red. This suite once had a test that passed with the guard it is named after removed,
because an unrelated check refused the write for it, and a guard with no test at all.
