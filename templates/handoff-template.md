---
title: Handoff → <node> — Operations Handbook
slug: handoff-<node>
status: stable
owner: <node>
updated: YYYY-MM-DD
tags: [handoff, operations]
---

# Handoff → <node> — Operations Handbook

> **Template — example data; fill it for your own node.** For the <node> thread/worker: how <node> operates inside the fleet.
> Fleet-wide model: see the architecture doc. This file is the node's contract:
> a new session (or a rebuilt machine) reads THIS first and knows how to behave.
> Header format: the same YAML front matter as every wiki article ([docs/02](../docs/02-llm-wiki.md)).

## Who <node> is
- Host `<hostname>`, worker user `<user>` (no sudo). Admin user `<admin-user>`: runs the jobs
  listed under *Privileged jobs* through a narrow root-owned wrapper — **never** "deploys only"
  if that is not literally true; list what it runs.
- Agent runtime: <CLI + profile dir(s) + subscription note>. **Every profile dir has its own
  memory store** — list them all: `<profile-dir-1>`, `<profile-dir-2>`.
- **Shared repos on this node:** `<repo>` (read-write, deploy key `<key-name>`) · `<repo>` (read-only).
  Account-wide tokens on this node: `<none | which, and why>`.

## Git — multi-writer rules for this node
- Canonical identity (set globally): `<noreply-identity>`; `origin-node: <node>` trailer on every automated commit.
- Writes only through the locked helpers (`git-safe-commit-push.sh`, `log-append.sh`); runtime clones stay on `main`, build in worktrees.
- Hygiene watcher: `git-hygiene-sync.sh` (cron :NN) — ff-pulls clean+behind, pushes clean+ahead, alerts otherwise, counts skips.
- Executable change (scripts, hooks, routines): branch → PR → **a different node merges**.

## Scheduled jobs on this node — GENERATED, not hand-maintained
> Produce this table with a script that reads the scheduler (launchd/cron) and checks
> the sums (plists == rows, cron lines == active + commented). A hand-kept table named
> two jobs that had not existed for weeks. Last generated: <date>, by `<script>`.

| Job | Runs as | Schedule | What | Record (`~/.records/<job>.record`, `max_age_s`) |
|---|---|---|---|---|
| <job> | `<user>` | cron `NN */6 * * *` | <what it does> | `<job>.record`, 46800 |

### Privileged jobs (admin user) — every one, with the owner of every file it executes
| Job | Executes | File owner | OK? |
|---|---|---|---|
| <job> | `<path>` | `<owner>` | must not be the agent user |

## Anti-patterns (stop immediately)
- ❌ <node-specific traps discovered the hard way — keep this list alive; date each entry>

## Open items — a register, not a list
> Prose to-do lists only grow (130 → 745 lines on one of ours). Every item has a **closing
> condition** and is removed when it is met; requests from other nodes arrive through the
> inbox ([docs/10](../docs/10-code-gates.md)), not by editing this file.

| Id | Item | Closes when | Opened | Evidence when closed |
|---|---|---|---|---|
| <id> | <what> | <observable condition> | <date> | <sha / record / link> |
