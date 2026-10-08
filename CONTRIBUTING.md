# Contributing

Thanks for looking. This project is maintained by people who run it on real hosts, so
reports of *how it failed for you* are more valuable than style opinions.

## Ground rules

1. **Windows PowerShell 5.1 compatibility.** No `??`, no ternary operator, no `-Parallel`,
   no classes. If it does not parse on 5.1 it will not be merged.
2. **UTF-8 with BOM for `.ps1` and `.vbs`.** Windows PowerShell 5.1 decodes scripts using
   the system code page when the BOM is missing, which corrupts non-ASCII text and can
   break parsing outright. See LESSONS.md item 7.
3. **No backtick line continuations.** They are easy to break in review and in generated
   files; split the expression instead.
4. **Tests before wording.** A failing test that demonstrates a bug is the fastest path to
   a fix. See `tests/README.md`.
5. **Keep the recovery path conservative.** Any change that makes the supervisor more
   willing to rewrite a configuration needs a corresponding safety argument in the PR.

## Reporting a failure

Include the supervisor log lines around the event, the configuration with hosts and
identifiers removed, and whether `-DryRun` reproduces it. A redacted configuration is
almost always enough to reproduce a decision bug.

## Reviewing

`docs/LIMITATIONS.md` lists the parts the author is least confident about. Reviews that
attack items 1, 3, 5 and 7 first are the most useful.

