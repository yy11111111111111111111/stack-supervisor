# Design

## Goals

- Detect **functional** failure, not just process failure.
- Recover without human intervention, and without making things worse when recovery is
  impossible.
- Keep working when the supervisors themselves are killed.
- Stay configurable: nothing about a particular service, protocol or vendor is hardcoded.

## Non-goals

- Load balancing or traffic shaping. The supervisor selects one endpoint at a time.
- Zero-downtime reconfiguration. A restart is acceptable and is the recovery mechanism.
- Managing more than one service per supervisor instance. Run two instances instead;
  the named mutex is derived from the service name.

## Layers

```
   ┌────────────────────────────────────────────────────────────────────┐
   │ L4  StackKeeper  - scheduled task, every 2 minutes                 │
   │     owns nothing but the component list; started by the OS         │
   ├────────────────────────────────────────────────────────────────────┤
   │ L3  ProcessKeeper - small loop, every 10 s (deployment specific)   │
   │     restarts the service process when it disappears                │
   ├────────────────────────────────────────────────────────────────────┤
   │ L2  StackSupervisor - resident loop, every 60 s                    │
   │     scores the data path, re-selects endpoints, verifies the write │
   ├────────────────────────────────────────────────────────────────────┤
   │ L1  Service - the thing that actually serves traffic               │
   └────────────────────────────────────────────────────────────────────┘
```

L3 is deliberately trivial and deployment specific: it only knows "if the process is
gone, start it". L2 knows about endpoints and configuration. L4 knows nothing except that
L1-L3 must exist, and it is the only layer whose lifetime the OS guarantees.

## Health state machine

```
                score 2            score 1                score 0
   ┌───────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
   │ reset both counters   │  │ failures = 0       │  │ degraded = 0       │
   │ (log recovery if any) │  │ degraded++         │  │ failures++         │
   └───────────────────────┘  └─────────┬──────────┘  └─────────┬──────────┘
                                        │                       │
                        degraded >= degradedThreshold   failures >= failThreshold
                                        │                       │
                                        └───────────┬───────────┘
                                                    ▼
                                        failover (unless cooling down)
```

Process-missing is a separate branch: it is not a health score, it is a missing
dependency. The supervisor waits `missingThreshold` rounds before starting the service
itself, so that the dedicated process keeper stays the primary owner of that job and the
two layers do not race.

## Candidate measurement

The naive approach - repoint the live service at each candidate and probe it - converts a
degraded service into a series of outages. Instead the supervisor builds a throwaway
configuration containing one instance per candidate:

```
probe config:
  inbound  127.0.0.1:11501 ──► upstream A
  inbound  127.0.0.1:11502 ──► upstream B
  inbound  127.0.0.1:11503 ──► upstream C
```

Each instance is a clone of the live endpoint object with new connection details, and the
supervisor only needs the template to know how to describe an instance - it never has to
understand the service's full configuration schema.

Measurement stops early once `wantHealthy` candidates have reached a full score, which
keeps a recovery round to a few seconds in the common case.

Each candidate's score is the lowest number of answering targets across all measurement
rounds. Ranking is `(score desc, total milliseconds asc)`, where total is the sum of round
durations. A good single round cannot hide a failed or degraded round.

## Configuration patching

The live configuration is edited as text, through source spans, not re-serialised from an
object graph:

1. A strict JSON tokenizer reads the whole file and records where every value starts and
   ends. It accepts JSON as RFC 8259 defines it and nothing else: comments, trailing commas
   and duplicate property names (anywhere in the file) are errors, not things to skip.
2. Locate the one object that carries the configured tag **and** every property from
   `requireProperties`. Zero or several matches refuse the write.
3. Apply `patchRules`. A `path`/`value` rule replaces exactly one scalar value, identified by
   its path inside that object, with the expanded template (strings are JSON-escaped,
   numbers and booleans are validated). Legacy `pattern`/`replacement` rules are still
   accepted, but each pattern must match exactly once inside the object. A rule that uses
   `{attr:name}` is switched off for a candidate without that attribute; only a rule that
   will write needs its path to exist.
4. Parse the patched file again, find the same object through the same JSON pointer, read
   host and port back from it, and compare them with the endpoint that was requested.
5. Back up the exact byte snapshot that was parsed. Write the replacement to a temporary file
   in the same directory, compare the current file with that snapshot, then atomically replace
   it. A concurrent writer can still race between the final comparison and the replace.

Step 2 is the important one. A configuration often mentions the endpoint tag in more than
one place - for example a forwarder object that contains a nested reference to the
endpoint's tag. Scanning for the first occurrence of the tag finds that nested reference
and rewrites the wrong object, silently disabling failover while every log line still
claims success. Requiring a sibling property (which a reference does not have) is what
makes the search unambiguous.

Why spans instead of parse-and-reserialise: re-serialising rewrites the whole file in the
serialiser's own layout and loses whatever the parser does not model, so diffs stop being
reviewable. Spans keep every byte outside the replaced values. The price is strictness.
Because the tokenizer has to know exactly where every value is, a file with comments or
other extensions cannot be edited this way and is refused rather than patched on a best
guess. Every refusal carries its reason to the log (syntax error with line and column,
"no object has tag ...", or the paths of an ambiguous match), because the supervisor runs
hidden and the log is the only diagnostic.

## Process identity

"Which process is the service" decides what gets stopped, so it is answered by two facts
together: the executable name (`processName`) and the absolute `configPath` appearing in
the process command line (`Win32_Process.CommandLine`, compared case-insensitively, with
`/` and `\` treated alike).

| Processes with that name | Carrying the config path | Result |
|---|---|---|
| none | - | the service is missing: the keeper acts first, the supervisor after `missingThreshold` rounds |
| any | exactly one | that process is the service; only it can be stopped |
| any | several | refuse: recovery is deferred and nothing is stopped |
| some | none, or the command lines are unreadable | refuse: recovery is deferred and nothing is stopped |

Stopping by name alone would stop a second instance of the same executable too, which is
why the path is part of the identity. The cost is that the rule fails closed: if the
service is started without its absolute config path (a relative `--config`, an environment
variable), or the supervisor is not allowed to read the command line, it neither scores
health nor fails over, and logs the reason every round.

A restart that cannot be carried out is a failed switch. The configuration written for it
is put back byte for byte, so the file never describes a state the running service did not
load, and no cooldown is consumed by a switch that did not happen.

The keeper does not use this rule yet: it detects the service by process name
(`detect.kind: process`), and its `commandLine` detection only inspects `powershell.exe`.
See LIMITATIONS.md.

## Keep-alive ownership

Mutual supervision between processes breaks down exactly when it matters: a cleanup tool,
a session logoff, or a process-tree kill can remove every supervisor at once. The keeper
therefore relies on the OS scheduler, which owns the process independently of any session,
and it can detect a component by command line rather than by process name, which is how it
tells two supervisors apart.

Detection patterns must exclude the detecting process itself. A check whose own command
line embeds the pattern it searches for will match itself and report a healthy stack that
does not exist.

## Failure modes

| Failure | Detected by | Recovery |
|---|---|---|
| Process crash | L3 (10 s) / L4 (2 min) | restart the process |
| Upstream silently degraded | L2 (60 s, score 1) | re-select endpoint |
| Upstream dead | L2 (60 s, score 0) | re-select endpoint |
| Every candidate bad | L2 candidate stage | keep the current configuration, retry next round |
| Local network down | L2 reachability pre-check | do nothing; the fault is local |
| Configuration write race | backup + read-back validation | refuse the write |
| Configuration cannot be read unambiguously (syntax error, no match, several matches, missing path) | `Get-JsonObjectBlock`, patch validation | refuse the write, log the reason |
| Service restart refused or incomplete after a write | `Restart-ServiceProcess` result | restore the previous configuration, end the attempt |
| Service cannot be identified (none or several carry the config path, unreadable command lines) | `Get-ServiceProcessSnapshot` | defer recovery, log the reason |
| Failover attempt raises an unexpected error | `Invoke-FailoverGuarded` | log it; the next round decides again |
| All supervisors killed | L4 scheduled task | start whatever is missing |
| Machine reboot | startup items + L4 | normal cold start |

## Extension points

- **Other services**: point `endpointSelector.tag` and `candidateTest` at another
  configuration file; nothing in the supervisor is service specific.
- **Other catalogs**: `catalog.format` supports a URI list, a base64-encoded URI list, or
  a local file (`catalog.file`).
- **More health targets**: add entries to `probe.targets`; the score becomes
  `targets passed / targets total`.
