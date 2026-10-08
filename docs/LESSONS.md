# Lessons

Incidents that shaped the design. Each entry is symptom, root cause, fix - all of them
were observed in production on a single Windows host, and all of them are generic.

## 1. A live process is not a working service

**Symptom.** The service process had been up for hours. Every request timed out. The
process supervisor saw a healthy process and did nothing for the next fifteen hours.

**Root cause.** Liveness was being measured on the wrong signal. A process can be running
while every dependency it needs is unreachable.

**Fix.** Probe the data path: ask the running service to fetch a known URL and assert on
the response body. Measure the thing users care about.

## 2. Binary health hides partial outages

**Symptom.** One health target answered, another timed out. Health checks treated the
service as healthy because "the request succeeded", while roughly half of all real
requests failed.

**Root cause.** Health was a boolean, so a partial outage looked identical to a full one.

**Fix.** Score the fraction of targets that answer correctly and act on a *run* of
degraded rounds, not on a single bad sample.

## 3. One measurement is noise

**Symptom.** A newly selected endpoint turned out to be the slowest in the candidate set,
even though the selection process had ranked it first.

**Root cause.** Candidates were ranked on a single probe. Variance between two probes of
the same endpoint was larger than the difference between endpoints.

**Fix.** Probe each candidate twice and rank on the sum. Ranking quality improved more
from this than from any tuning of thresholds.

## 4. Do not defer to a supervisor you have not checked

**Symptom.** A 99-minute outage. The health supervisor logged, once a minute, that the
service was missing and that it was "deferring to the process supervisor". The process
supervisor was not running, so nobody started the service.

**Root cause.** The deferral was unconditional: it assumed the other component existed.

**Fix.** Count the rounds a dependency has been missing, and take over after a threshold.
Deferring is a policy, not a guarantee.

## 5. Supervisors need a supervisor the OS owns

**Symptom.** Twice, every supervisor started from an interactive session disappeared
within a few hours, leaving nothing to restart the service. Components started by the
scheduler or at logon survived.

**Root cause.** Process trees can be torn down by the session that created them; anything
hosted inside such a tree dies with it. Mutual supervision cannot cover a failure that
removes all supervisors at once.

**Fix.** A scheduled task that owns the component list. It is registered with the OS, so
it survives session teardown, and it is the only layer that is guaranteed to run.

## 6. Task Scheduler plus a console application equals a flashing window

**Symptom.** A black console window appeared on the desktop every two minutes. Users
notice this immediately and it looks like something is wrong.

**Root cause.** The scheduler starts the payload in the interactive session. A console
application gets a console window even when the command line asks for a hidden window.

**Fix.** Register the task against a launcher hosted by a GUI-subsystem interpreter
(`wscript.exe` + a two-line `.vbs`) and pass `0` as the window style. No window is
created at all. Verified by checking that the payload process reports a null main window
handle.

## 7. Windows PowerShell 5.1 reads scripts as ANSI unless they start with a BOM

**Symptom.** A script that parsed and ran correctly in the editor failed with parse errors
about unterminated strings, and every non-ASCII character in the error output was garbage.

**Root cause.** PowerShell 5.1 decodes `.ps1` files using the system code page when there
is no byte-order mark. UTF-8 text without a BOM is misread, and a multi-byte character can
consume the closing quote of a string literal.

**Fix.** Always write scripts as UTF-8 **with** BOM. Watch for tooling that silently strips
it on save - the failure returns immediately after any such edit.

## 8. Text-level JSON patching needs an unambiguous anchor

**Symptom.** Failover reported success on every run and did nothing at all. The
configuration file was untouched.

**Root cause.** The patcher searched for the first occurrence of the endpoint tag. The
file contained a nested reference to that same tag inside a forwarder object, which
appeared earlier, so the wrong object was selected - one that had none of the fields the
patcher wanted to rewrite.

**Fix.** Accept only objects that carry the tag **and** a required sibling property that a
mere reference cannot have. Then validate by re-parsing and reading the fields back.

## 9. Detection filters can match the command that runs them

**Symptom.** A component was reported as running while it was not; later, an installer
killed itself while trying to stop a "duplicate" process.

**Root cause.** The filter searched the process command lines for a pattern that the
filtering command itself contained, so it matched itself.

**Fix.** Exclude the current process id, and prefer anchored patterns over loose substring
matches.

## 10. Logs need an encoding decision

**Symptom.** A log file was unreadable in every editor and the encoding looked corrupt.

**Root cause.** The writer used UTF-16 (the default of one particular cmdlet) while every
reader assumed UTF-8. Non-ASCII entries turned into noise and history could not be read
back during an incident.

**Fix.** Choose one encoding deliberately and use it in every writer. For Windows tools
that expect a BOM, UTF-8 with BOM is the pragmatic choice.

## 11. Recovery must not be able to make things worse

**Symptom.** None - this one was designed in after the near misses above. Every rule here
exists because a recovery path can be the outage.

**Rules.**
- Back up before writing, keep the last N backups.
- Validate the new file before it replaces the old one.
- Prefer no change: only switch when the candidate is strictly better.
- Cool down after every switch.
- Provide a dry-run mode that exercises the whole pipeline and writes nothing.
- When the local network is down, do nothing at all.

## 12. Keep the measurement path off the serving path

**Symptom.** Recovery attempts briefly took the service down for every candidate tried.

**Root cause.** Candidates were tested by repointing the live service at each one in turn.

**Fix.** Start throwaway instances on alternate ports, one per candidate, and measure them
in parallel with production traffic. The live configuration is written exactly once, after
a winner has been chosen and verified.
