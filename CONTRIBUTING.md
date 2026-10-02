# Contributing

Improvements welcome — especially:

- **Portability fixes** (the scripts target macOS/bash 3.2; Linux PRs welcome)
- **New failure modes + guards** you hit running a fleet (the "hard-won rules" list grows from real incidents)
- **Clarity fixes** in the docs — this repo is used for teaching

Ground rules:

1. **No personal data, hostnames, IPs, or credentials** in any contribution — use the established placeholders (`hub`, `worker-a`, `worker-b`, repos `wiki`/`memory`/`node-memory`, example projects like `kestrel`).
2. Scripts must pass `bash -n`, stay bash-3.2-compatible (macOS default), and keep `tests/harness.sh` (64 checks) and `tests/aux-scripts.sh` (28 checks) green — add a test for every new guard; Python must be ≥ 3.9 stdlib-only and pass `python3 -m py_compile`.
3. Keep docs in the established voice: short intro → mechanics (tables) → failure modes & guards → minimal setup steps.

Open an issue first for larger changes.

Pull requests are reviewed by a human **and** by an independent verification pass (two separate reviewers: one for privacy/injection, one for function against the tested invariants). A PR that touches scripts is run only inside the throwaway harness, never on a live machine. Expect the review to ask for the test that proves the fix.
