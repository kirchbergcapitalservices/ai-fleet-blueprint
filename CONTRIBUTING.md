# Contributing

Improvements welcome — especially:

- **Portability fixes** (the scripts target macOS/bash 3.2; Linux PRs welcome)
- **New failure modes + guards** you hit running a fleet (the "hard-won rules" list grows from real incidents)
- **Clarity fixes** in the docs — this repo is used for teaching

Ground rules:

1. **No personal data, hostnames, IPs, or credentials** in any contribution — use the established placeholders (`hub`, `worker-a`, `worker-b`, repos `wiki`/`memory`/`node-memory`, example projects like `kestrel`).
2. Scripts must pass `bash -n` and stay bash-3.2-compatible (macOS default).
3. Keep docs in the established voice: short intro → mechanics (tables) → failure modes & guards → minimal setup steps.

Open an issue first for larger changes.
