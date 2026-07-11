# Worker Brief — Template

> A delegation without a written brief produces confident garbage. This template
> is the minimum. Send via your worker helper: `worker-a-claude -f brief.md -b`

# Task for worker-a: <one-line title>

Context: <2-4 sentences — why this exists, what decision/goal it serves, what
already exists that the worker should NOT rebuild.>

## Tasks (idempotent, EXACTLY these, in order)
1. <concrete step with exact paths/commands — no room for interpretation>
2. <verification step with expected output — "must print X">
3. <...>

## Report (as the LAST lines of your answer, compact)
```
1 <step>: OK/FAIL
2 <step>: OK/FAIL (<error text if FAIL>)
...
```

## HARD DON'Ts
- Do NOT touch repos/files outside the listed paths.
- Do NOT commit/push unless a task explicitly says so (and then only via safe-push).
- Do NOT generate keys / call GitHub admin APIs / change schedules.
- NO secrets, key material, or tokens in your output.
- If a step fails: report FAIL + stop dependent steps — do NOT improvise workarounds.

# Why the DON'Ts matter (for the human writing the brief)
Workers run headless with permissions skipped. The brief IS the permission
boundary. Scope tightly; verification steps make the report trustworthy;
the report format makes results machine-checkable back on the hub.
