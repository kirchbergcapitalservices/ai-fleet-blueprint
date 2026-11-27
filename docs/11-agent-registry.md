# 11 — The agent registry: one source of truth for every agent and skill

Once you have more than a handful of agents, the question stops being "how do I write a good
agent?" and becomes "which agents exist, who owns them, and is every machine running the same
ones?" Agent CLIs answer that per installation: one folder of agent files, one folder of skills,
on one machine, for one tool. That is fine for a laptop. It breaks the moment a second machine,
a second model vendor or a second team joins.

The fix is boring and it works: **agents and skills live in their own git repository**, next to
the wiki, and every machine *consumes* that repository instead of keeping its own copy.

## Why a separate repository (and not a folder in the wiki)

| Question | Wiki repo | Registry repo |
|---|---|---|
| What is it? | knowledge — what is true about the world | behaviour — what the agents do |
| Who writes? | every node, 100+ commits a day, no review | few changes, each reviewed before merge |
| What happens on merge? | nothing runs | every node starts behaving differently |
| Protection | none on `main` (multi-writer) | branch protection, PR required ([docs/10](10-code-gates.md)) |

An agent definition is executable in the sense that matters: it changes what runs, on every
machine, from the next session on. It belongs in the code tier, not in the content tier.

## The layout

```
agent-registry/
  README.md                 # domains, owners, the rules below
  ADDING-AN-AGENT.md        # the checklist a new agent passes before merge
  agents/
    shared/                 # truly generic: verifier, researcher, editor — reuse before you copy
    <domain>/               # one folder per business domain, each with a README naming its owner
      <slug>.md
  skills/<slug>/SKILL.md    # multi-step procedures an agent can load on demand
  routines/<name>.md        # thin prompts for scheduled runs — they call a skill, nothing more
  scripts/                  # install, sync, lint
```

Three rules keep it from turning into a junk drawer:

1. **Reuse `shared/` before you duplicate.** A second "researcher" with a slightly different
   prompt is how a registry grows to 80 agents nobody can tell apart.
2. **A new domain is a new folder with a README that names its owner** and a short role plan
   (which agents, which ones are still missing, which ones were retired and why).
3. **Changes to a domain you do not own go through its owner.** Not as politeness — as the
   mechanism that keeps two people from tuning the same agent in opposite directions.

## What every agent file carries

The agent CLI needs a name, a description and a prompt. The registry needs more, because the
registry is read by *other agents* deciding whom to call. Use a front-matter block like the one in
[templates/agent-definition-template.md](../templates/agent-definition-template.md):

| Field | Why the registry needs it |
|---|---|
| `name`, `description` with **trigger phrases** | the orchestrator picks agents by description; vague descriptions are never picked |
| `owner` (a domain or a person) | someone answers for it when it misbehaves |
| `tools` — the minimum | an agent that only reads cannot be talked into writing |
| `model` / engine | which model runs it — the registry is model-neutral, the file says which one |
| `gates` | the actions this agent may never take alone (send, publish, pay, delete) |
| `pairs_with` | its reviewer: an author agent names the independent agent that checks it |
| `status` | `active`, `trial`, `retired` — retired files stay, with the reason, so nobody rebuilds them |

## One registry, many models

A registry that only speaks one vendor's agent format will be outdated within a quarter. Keep the
**definition** neutral (Markdown + front matter) and let a thin wrapper decide how to run it: as a
sub-agent of your main CLI, as a prompt for a second model, as a scheduled run. Our registry
started as "all Claude agents and skills"; within months the same files were driving reviews on a
second model family, because the wrapper picks the engine and the file only states its needs (see
[docs/09](09-second-engine-broker.md)).

## How a machine consumes the registry

Every machine keeps **two checkouts** of the same repository:

| Checkout | State | Who points at it |
|---|---|---|
| **work checkout** | on feature branches, edited, pushed, PRs opened from here | nobody — nothing at runtime reads it |
| **live checkout** | a `git worktree`, detached on `origin/main`, **never edited** | the agent CLI's agent and skill folders (symlinks), hooks, scheduled runs |

A sync job (every 15 minutes) fetches and moves the live checkout to the new `origin/main` — but
only if the live checkout is clean. A dirty live checkout is an alarm, not something to clean up.
A long-running job must finish on the version it started with. Recording the commit is not
enough — the symlinks still point at a checkout the sync can move. Either the sync and the runner
share one lock (the sync waits while a run holds it), or each run starts from its own checkout of
that commit. Jobs that run with admin rights load only
files an administrator owns — never straight from a checkout an agent can write to.

Why the split matters: before it, our symlinks pointed into the work checkout, and every machine
ran whatever feature branch it happened to be on. One morning three machines ran three different
sets of agents, and nobody noticed for hours. (Same lesson as [docs/04](04-multi-writer-git.md):
a runtime clone is not a workbench.)

The pay-off is the part people notice first: **a new machine is one clone and one install script
away from knowing every agent, every skill and every rule the fleet has.** It connects to the
repository, and it is online — same agents, same gates, same reviewers as everyone else.

## Changing the registry: curate, then merge somewhere else

1. Branch from `main` in the work checkout. Write or change the agent.
2. Run a **curator** — itself an agent in the registry — on the branch *before* asking anyone:
   front matter complete? description specific enough to be picked? does `shared/` already have
   this? any secret or private name in the text? tools minimal? It answers MERGE,
   MERGE-WITH-FIXES or BLOCK.
3. Open the PR. The second-model review and the merge follow the code gates of
   [docs/10](10-code-gates.md).
4. **Merge is not deploy.** A merge changes the repository; the sync jobs change the machines. If
   you want a human in that loop, put the gate on the *deploy* (who may move the live checkouts),
   not on the merge.

## The team is never finished: the periodic review

Human organisations re-plan their teams once a year. An agent team should re-plan itself on a
schedule — weekly is not too often — because models, connectors and the work itself change faster
than any org chart.

A **registry review** run (an organisation-design agent, independent of the orchestrator it
reviews) reads three things: the registry, the record of recent assignments (who was called, how
often, with which verdict), and the open work. It proposes, never applies:

| Signal | Proposal |
|---|---|
| two agents with overlapping descriptions, both called rarely | merge them |
| an agent not called in 60 days | retire it, with the reason in its file |
| the same review finding three times for one author agent | change the author's prompt, not the reviewer's |
| work arriving that no description matches | a new agent — specified, then built and curated like any other |
| an agent whose reviewer never finds anything | check the reviewer with a planted error before you trust the silence |

The proposals go through the same branch → curator → PR path. That loop — work, measure, propose,
review, merge — is what turns a set of prompts into an organisation that improves itself.

One observation from our own setup: agents you never see one-on-one get optimised ruthlessly,
because nobody is attached to them. The agents you talk to every day get improved least. Put
those on the review schedule on purpose.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| every machine keeps its own copy of the agents; they drift | one registry repo; machines consume it, never copy it |
| a machine runs a feature branch because the symlinks point at the work checkout | separate live worktree, detached on `origin/main`, never edited |
| 80 agents, half of them near-duplicates | reuse `shared/` first; curator checks for overlap before merge; periodic review merges and retires |
| an agent is never picked | description with concrete trigger phrases; the review lists agents with zero calls |
| an agent changed by two people in opposite directions | domain folders with a named owner; foreign changes go through the owner |
| a retired agent is rebuilt three months later | retired files stay, with `status: retired` and the reason |
| a merge silently rewrites behaviour on every machine | PR + second-model review; optional human gate on the deploy step |
| the registry speaks one vendor's format only | neutral Markdown definitions; a wrapper chooses the engine |

## Minimal setup steps

1. Create a private `agent-registry` repository. Move your agent and skill files into `agents/`
   and `skills/`; create `agents/shared/` for the generic ones.
2. Add the front-matter fields above to every agent ([template](../templates/agent-definition-template.md)).
   Agents without an owner or a pairing get one now — or get retired.
3. Turn on branch protection for `main`: PR required, also for admins, plus the required review
   check from [docs/10](10-code-gates.md).
4. On each machine: create the live worktree, point the agent CLI's folders at it with symlinks,
   and schedule the sync (fetch, then switch the live worktree only if it is clean **and no run
   holds the shared lock**).
5. Write `ADDING-AN-AGENT.md` and a curator agent that checks it.
6. Schedule the registry review — weekly — and route its proposals through the normal PR path.
