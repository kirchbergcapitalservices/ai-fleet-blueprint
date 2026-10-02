# Worker Brief — Template

> **Template — example data, not a live brief.** A delegation without a written brief produces
> confident garbage; this template is the minimum. In your own fleet a brief like this is handed to
> a worker helper or dropped as a task file into the node's inbox ([docs/05](../docs/05-worker-delegation.md)).

# Task for worker-a: <one-line title>

Context: <2-4 sentences — why this exists, what decision/goal it serves, what
already exists that the worker should NOT rebuild. Give the CURRENT state, dated;
mark your own assumptions as assumptions.>

## Requirements (stable ids — never renumber)
- REQ-1 <concrete, checkable — exact paths/commands, no room for interpretation>
- REQ-2 <verification step with expected output — "must print X">
- REQ-3 <...>

## Non-goals (also stable ids)
- NG-1 <what must stay untouched, e.g. "no change to scripts/ outside <dir>">
- NG-2 <e.g. "no commit to main; branch worker-a/<topic> only">

## Report — the scope ledger (as the LAST lines of your answer)
```
REQ-1: PASS | FAIL (<error>) | UNTESTED (<why>) — evidence: <command/output or commit sha>
REQ-2: ...
NG-1: untouched — checked by <how>
NG-2: ...
Other behavior changes: None
Delivered: <commit sha(s)> pushed to <remote/branch>   # "done" means pushed, with the hash
Not checked: <list or "none">
```

## HARD DON'Ts
- Do NOT touch repos/files outside the listed paths.
- Do NOT generate keys / call GitHub admin APIs / change schedules.
- NO secrets, key material, or tokens in your output.
- If a step fails: report FAIL + stop dependent steps — do NOT improvise workarounds.
  A REQ you can only meet by violating an NG is a CONFLICT to report, not a choice to make.
- Retry cap: 3 attempts per step, then FAIL.
- Anything that must outlive this turn: `nohup … &` + its own record (headless iron rule).

# Why this shape matters (for the human writing the brief)
The DON'Ts bound the worker's **scope**; they are not its permission boundary. Permissions
come from the unprivileged OS user, the CLI deny-list and the sandbox ([docs/07](../docs/07-security.md)) —
those hold even when the brief is misread or injected around. Stable REQ/NG ids make the
report diffable against the brief; "evidence: <sha>" makes it checkable; and the requester
verifies delivery at the receiving end (own pull, own file count), never by the sender's word.
