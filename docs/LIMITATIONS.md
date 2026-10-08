# Known limitations and open questions

This supervisor runs in production on one host, but parts of it are best described as
*the first version that survived the incidents in LESSONS.md*, not as finished work.
The list below is deliberately blunt. It includes current risks and recently addressed
items with their status, so contributors can see both where review effort pays off and
which issue references have been closed by code.

## Risk areas and status

| # | Area | Concern | Severity | Status |
|---|---|---|---|---|
| 1 | `Invoke-GatewayProbe` | A buffering reader could consume bytes after the CONNECT header terminator. | High | Resolved: exact-length header reader |
| 2 | `Invoke-GatewayProbe` | `RemoteCertificateValidationCallback { $true }` disables certificate validation even though the response body drives a recovery decision. | Medium | Open |
| 3 | `Get-JsonObjectBlock` | Brace scanning could misidentify the object to rewrite. | High | Resolved: strict JSON tree with source spans |
| 4 | `Set-ActiveEndpoint` read-back | Heuristic object search could validate the wrong endpoint. | Medium | Resolved: read back through the selected JSON pointer |
| 5 | Patch rules | Replacing the first regex match could rewrite a nested field. | High | Resolved for path rules; legacy rules require one match |
| 6 | `Start-ServiceProcess` | Regex command splitting can break paths with spaces or complex arguments. | Medium | Open |
| 7 | `Restart-ServiceProcess` | Stopping by process name could kill a second instance. | High for multi-instance hosts | Resolved: stop only one config-path match |
| 8 | Catalog fetch | Windows PowerShell 5.1 may use legacy TLS defaults for `Invoke-WebRequest`. | Medium | Open |
| 9 | Test coverage | Automated tests now cover the priority regressions, but many operational paths remain untested. | Critical for contributors | Partial |
| 10 | Logging | Append-only with no rotation, no size cap, no structured format and no counters. | Low to Medium | Open |
| 11 | Candidate fan-out | Every probe instance starts at once: `maxCandidates = 8` means 8 processes and 8 generated files at peak. | Medium on small hosts | Open |
| 12 | Mutex granularity | The single-instance mutex is keyed on the service name alone, so two supervisors with different configurations for the same service would exclude each other. | Low | Open |
| 13 | Reachability probe | `Test-UpstreamReachability` hardcodes `1.1.1.1:443`. | Low | Open |
| 14 | `-ForceSwitch` semantics | Forced mode ignores the *strictly better* rule as documented, but it also skips the cooldown. That combination is easy to misuse. | Low | Open |
| 15 | Locale assumptions | Timestamps and `yyyyMMddHHmmss` backup names are assumed to be locale independent. Not verified under non-Gregorian calendars or unusual regional settings. | Low | Open |

## Design decisions and open questions

1. **Text patching versus parse and re-serialise.** Keep text patching so formatting and
   comment-like data properties survive, but parse the JSON structure and use source spans
   for exact object and value paths. New `patchRules` use `path` and `value`; legacy
   `pattern`/`replacement` rules remain compatible only when each pattern has exactly one
   match. Duplicate JSON keys, ambiguous endpoint objects and ambiguous legacy matches are
   rejected before a write.
2. **Stopping a service without a manager.** Match the executable name and configured
   configuration path from `Win32_Process.CommandLine`, then stop only the unique PID.
   If the command line is unavailable or the match is ambiguous, refuse the restart rather
   than kill every same-named process. A Windows service manager or a process handle carried
   from launch would provide a stronger ownership boundary.
3. **What the health score should mean.** Today it is *how many targets answered*. A slow
   but correct target counts exactly like a fast one. Should latency influence the score, or
   stay strictly separate from availability?
4. **Where the keeper boundary belongs.** The keeper starts components but does not verify
   that they stay up. A component that starts and dies immediately is restarted on every
   interval, with no rate limiting and no crash-loop detection.

## Where help is most valuable

1. Review the Pester suite and add cases for remaining failure modes as they are fixed.
2. Review the remaining open limitations, especially certificate validation and command-line
   parsing in the restart path.
3. The source-span patching decision above is implemented; feedback on its configuration
   compatibility and failure behavior is useful.
