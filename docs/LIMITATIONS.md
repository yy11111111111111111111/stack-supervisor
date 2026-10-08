# Known limitations and open questions

This supervisor runs in production on one host, but parts of it are best described as
*the first version that survived the incidents in LESSONS.md*, not as finished work.
The list below is deliberately blunt. It is the map of where review effort pays off most,
and it is the reason the repository asks for help rather than presenting itself as done.

## Things the author is not confident about

| # | Area | Concern | Severity |
|---|---|---|---|
| 1 | `Invoke-GatewayProbe` | Response headers are read with a `StreamReader` wrapped around the socket stream, then the body is read from the same underlying stream. A buffering reader can consume bytes past the header terminator, which would truncate the body and make a healthy target look broken. | High |
| 2 | `Invoke-GatewayProbe` | `RemoteCertificateValidationCallback { $true }` disables certificate validation completely. Fine for a liveness probe, wrong the moment the body is used for a decision with security meaning. | Medium |
| 3 | `Get-JsonObjectBlock` | Brace matching is string- and escape-aware, but it is hand-written. Braces inside strings, unusual escape sequences, or comment syntax would confuse it, and it is the component that decides *which object gets rewritten*. | High |
| 4 | `Set-ActiveEndpoint` read-back | After re-parsing, the patched object is located by walking every array-valued property looking for a matching tag. That is a heuristic, not a path lookup, and it could validate the wrong object. | Medium |
| 5 | Patch rules | `patchRules` replace the **first** match inside the block. A pattern that also matches a nested field silently rewrites the wrong value. | High |
| 6 | `Start-ServiceProcess` | The start command is split with a regular expression. Paths with spaces, embedded quotes or `=` inside arguments will break it. | Medium |
| 7 | `Restart-ServiceProcess` | The service is stopped by process **name**. Two instances of the same executable would both die. | High for multi-instance hosts |
| 8 | Catalog fetch | `Invoke-WebRequest` under Windows PowerShell 5.1 uses legacy TLS defaults unless `ServicePointManager` is configured, so a modern endpoint can fail with a confusing message. | Medium |
| 9 | No tests | There is **no automated test of any kind**. Every path was validated against a live host, by hand. | Critical for contributors |
| 10 | Logging | Append-only with no rotation, no size cap, no structured format and no counters. | Low to Medium |
| 11 | Candidate fan-out | Every probe instance starts at once: `maxCandidates = 8` means 8 processes and 8 generated files at peak. | Medium on small hosts |
| 12 | Mutex granularity | The single-instance mutex is keyed on the service name alone, so two supervisors with different configurations for the same service would exclude each other. | Low |
| 13 | Reachability probe | `Test-UpstreamReachability` hardcodes `1.1.1.1:443`. | Low |
| 14 | `-ForceSwitch` semantics | Forced mode ignores the *strictly better* rule as documented, but it also skips the cooldown. That combination is easy to misuse. | Low |
| 15 | Locale assumptions | Timestamps and `yyyyMMddHHmmss` backup names are assumed to be locale independent. Not verified under non-Gregorian calendars or unusual regional settings. | Low |

## Design questions without a good answer yet

1. **Text patching versus parse and re-serialise.** Text patching preserves formatting and
   comments but requires patterns that are unique by construction. Parse and re-serialise is
   exact but reformats the file and loses comments. A parser that reports source spans for
   the values it found would give both properties; that is not built here.
2. **Stopping a service by name.** A reliable restart wants a process handle, a job object
   or the platform service manager. Matching on the process name is the weakest link in the
   whole recovery path.
3. **What the health score should mean.** Today it is *how many targets answered*. A slow
   but correct target counts exactly like a fast one. Should latency influence the score, or
   stay strictly separate from availability?
4. **Where the keeper boundary belongs.** The keeper starts components but does not verify
   that they stay up. A component that starts and dies immediately is restarted on every
   interval, with no rate limiting and no crash-loop detection.

## Where help is most valuable

1. A Pester test suite - see `tests/README.md` for the harness the suite is expected to use.
   Regression tests for items 1, 3, 5 and 7 would pay for themselves immediately.
2. Fixes for the High items above.
3. A decision, and an implementation, for design question 1.

