<!-- type: workflow -->
<!-- status: active -->
<!-- updated: YYYY-MM-DD -->

# Handoff → <node> — Operations Handbook

> **For the <node> thread/worker.** How <node> operates inside the fleet.
> Fleet-wide model: see the architecture doc. This file is the node's contract:
> a new session (or a rebuilt machine) reads THIS first and knows how to behave.

## Who <node> is
- Host `<hostname>`, worker user `<user>` (no sudo; `<admin-user>` = deploys only).
- Agent runtime: <CLI + profile dir + subscription note>.
- **Shared repos on this node:** `<repo>` (read-write, deploy key `<key-name>`) · `<repo>` (read-only — hub curates).

## Git — multi-writer rules for this node
- Canonical identity (set globally): `<noreply-identity>`. Never a machine-generated one.
- Pull before edit; commit + push immediately after. Nothing left uncommitted/unpushed.
- Hygiene watcher: `git-hygiene-sync.sh` (cron :NN) — ff-pulls when clean, alerts otherwise.

## Scheduled jobs on this node
| Job | Schedule | What | Heartbeat |
|---|---|---|---|
| <job> | cron `NN */6 * * *` | <what it does> | `~/.heartbeats/<job>.done` |

## Anti-patterns (stop immediately)
- ❌ <node-specific traps discovered the hard way — keep this list alive>

## Open / follow-up
- <tasks queued for this node's next session — the hub writes requests HERE,
  the node's thread executes them and marks them ✅ DONE with evidence>
