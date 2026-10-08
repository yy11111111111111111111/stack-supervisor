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

Ranking is `(score desc, total milliseconds asc)`, where total is the sum of two rounds.
This is not cosmetic: ranking on a single sample once promoted the endpoint with the
worst true latency in the candidate set.

## Configuration patching

The live configuration is treated as text, not as a serialised object graph:

1. Locate the object that carries the configured tag **and** a sibling property from
   `RequireProperty` (default `protocol`).
2. Rewrite only the fields that describe the endpoint.
3. Re-parse the whole file and read the changed fields back.
4. Back up the previous file, then write.

Step 1 is the important one. A configuration often mentions the endpoint tag in more than
one place - for example a forwarder object that contains a nested reference to the
endpoint's tag. Scanning for the first occurrence of the tag finds that nested reference
and rewrites the wrong object, silently disabling failover while every log line still
claims success. Requiring a sibling property (which a reference does not have) is what
makes the search unambiguous.

Text patching is chosen over parse/serialise because it preserves formatting, ordering and
comments, which keeps diffs reviewable and avoids surprises with duplicate keys.

## Keep-alive ownership

Mutual supervision between processes breaks down exactly when it matters: a cleanup tool,
a session logoff, or a process-tree kill can remove every supervisor at once. The keeper
therefore relies on the OS scheduler, which owns the process independently of any session,
and it detects components by command line rather than by process name so it can tell two
supervisors apart.

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
| All supervisors killed | L4 scheduled task | start whatever is missing |
| Machine reboot | startup items + L4 | normal cold start |

## Extension points

- **Other services**: point `endpointSelector.tag` and `candidateTest` at another
  configuration file; nothing in the supervisor is service specific.
- **Other catalogs**: `catalog.format` supports a URI list, a base64-encoded URI list, or
  a local file (`catalog.file`).
- **More health targets**: add entries to `probe.targets`; the score becomes
  `targets passed / targets total`.
