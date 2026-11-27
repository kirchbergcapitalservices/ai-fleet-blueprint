# 12 — From one operator to a group of companies: global layer, local machines

Everything up to chapter 11 describes one operator with a laptop and a few always-on machines.
The next question comes as soon as one person's setup works: *what if the organisation is a
group of independent companies, each with its own IT, its own office tenant and its own rules?*

This chapter is our answer. It is a design we use in parts and recommend in full — read it as a
pattern with its reasons, not as a finished rollout. Where it is untested at group scale, it says
so.

## The shape: one global layer, one machine per company

```
                 ┌──────────── group GitHub organisation (held by the group) ────────────┐
                 │  wiki (group knowledge) · agent-registry (global agents) · templates   │
                 └──────▲──────────────────────▲──────────────────────▲──────────────────┘
                        │                      │                      │
              headless machine A      headless machine B      headless machine C
              company A network       company B network       company C network
              + local repos           + local repos           + local repos
              (company-only data)     (company-only data)     (company-only data)
```

| Layer | Holds | Who administers |
|---|---|---|
| **Global** — one GitHub organisation | the shared wiki, the global agent registry, templates, the rules | the group (the holding, or whoever runs the programme) |
| **Local** — one headless machine per company, inside its own network | the company's own connectors (mail, ERP, files), local repos for data that must not leave the company, local agents | the company, with an operator |

The machines pull the global layer like any node in [docs/01](01-architecture.md). What they
connect to locally stays local. **The global layer carries patterns and shared knowledge; the
local layer carries company data.** That one sentence answers most of the data-protection
questions before they are asked.

## Why GitHub as the global layer (and not the office suite)

We are often asked "why not Teams/SharePoint — everyone already has it?" Both can work as a place
for files. The difference shows up when agents, not people, are the main writers:

| Need | Git hosting | Office file platform |
|---|---|---|
| every change attributable and reversible | built in: every write is a commit, several files at once | version history per file |
| three agents writing at once without losing work | merge, rebase, locks ([docs/04](04-multi-writer-git.md)) | real-time co-authoring for office documents; for other files (Markdown, JSON, scripts) concurrent writes end in an overwrite or a sync conflict copy |
| review before a change goes live | pull requests, branch protection ([docs/10](10-code-gates.md)) | approval flows exist, but are separate from the file |
| a new machine is complete after one command | `git clone` | depends on sync clients and per-user permissions |
| model- and vendor-neutral | plain files any agent CLI reads | tied to one suite's connectors |
| crosses company tenants | one organisation, members from anywhere | external sharing works, but follows each tenant's sharing policy — check before you rely on it |

None of this makes the office suite wrong as the *front end* — people can keep reading, approving
and chatting where they already work. The point is where the **truth** lives.

**Start on hosted GitHub.** If the setup grows and policy demands it, the same repositories can
move to a self-hosted GitHub Enterprise Server later with GitHub's migration tooling; that is a migration, not a redesign (large-file storage and some settings move separately).
Sensitive data that must never reach any hosted service stays in a bare git repository on a
machine in your own network ([docs/01](01-architecture.md), layer 0) — same workflow, different
remote.

## Who holds the organisation

The group holds it — not a person, not one of the companies.
In practice: an organisation owned by the holding, two owners (never one), everyone else a member
with the least rights that work. If the group already has a GitHub organisation, **use it**
rather than creating a second — two organisations for one programme is two sets of settings to
keep tight.

Before the first agent connects, harden the organisation. The checklist is in
[templates/github-org-hardening-checklist.md](../templates/github-org-hardening-checklist.md);
the essentials:

- **two-factor authentication required** for every member — nobody connects without it;
- **base permission "none"** for members; access is granted per repository, per team;
- **one team per company**, plus a small global team for the shared repositories;
- **no app or integration connects without an owner's approval**; fine-grained tokens need owner approval, classic tokens are blocked;
- branch protection on the repositories that drive behaviour (registry, scripts) — on private
  repositories this needs GitHub Team or higher;
- **single sign-on later**: with a handful of people, managing members by hand is fine; when you
  widen access beyond a handful of people, move to SSO against your identity provider (this needs the
  enterprise tier — budget for it then, not now).

## Why a headless machine in your own network (and not a cloud VM)

Both work. We run ours in-house and recommend it for a start, for four reasons:

1. **It is like hiring an employee.** It sits in the network, behind the same firewall, reaches
   the same file shares and systems a colleague would — no new tunnel, no new exception.
2. **You administer it.** No ticket to a cloud team when a connector needs a new permission.
3. **Cost is a one-off**, not a monthly bill that grows with every always-on job.
4. **Company data stays where it already is.** The machine reads it there; only the patterns and
   the shared knowledge go up to the global layer.

What you take on in return: power, updates, backups and a watchdog — all of which
[docs/06](06-watchdogs.md) covers. And one rule: **not the laptop.** Recursive improvement,
scheduled runs and the inbox need a machine that is on at 3 a.m.

## Global or local? A rule each company can apply alone

Every agent, skill and article answers one question before it is merged: *would another company
in the group benefit from it, and may it see it?*

| Answer | Where it goes |
|---|---|
| useful for others, contains nothing company-specific | global wiki / global registry, via PR |
| useful for others, but built on company data | a **sanitised** version goes global; the original stays local |
| company-specific, or regulated differently in this country | local repository on the company's machine |
| a regulatory or policy difference | the global version states the rule; the local version records the deviation and why |

Each company decides for itself what it pushes up. The global layer never pulls from a company
machine; a named person at the company submits the sanitised copy as a pull request — the
machine's own keys stay read-only on the global repositories.

That direction is **one** boundary, not the only one. Data also leaves through prompts sent to
hosted models, review bots, alerts and chat notifications. Decide per data class which of those
exits it may take ([docs/09](09-second-engine-broker.md), the data-class gate), before the first
connector is switched on.

## How to start: one machine, then two

Do **not** start with the group. Start with yourself.

| Step | What | Done when |
|---|---|---|
| 0 | Install git and the agent CLI, sign in to GitHub, clone a test repository, open and merge one pull request by hand | you have seen a PR from both sides |
| 1 | Harden the organisation; create `wiki` and `agent-registry` | checklist ticked, two owners |
| 2 | Your own headless machine, outside every company's infrastructure | it runs a scheduled job and reports a heartbeat |
| 3 | Your organisation of agents on it ([docs/13](13-ai-native-organisation.md)) | one real assignment ran through orchestrator, specialist and reviewer without you passing messages |
| 4 | A **second** machine, in one company, with its own operator | both machines pull the same registry |
| 5 | First global-vs-local decision made by that company alone | one sanitised item went up through a PR |
| 6 | Onboard the next company with [templates/new-entity-onboarding.md](../templates/new-entity-onboarding.md) | — |

Why outside the companies' infrastructure first: inside it, every licence, every connector and
every exception is a ticket, and a long wait for an IT change kills a pilot. Prove the
pattern where you control the machine, then bring it into the companies.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| the programme lives in one person's account and leaves with them | organisation held by the group, two owners |
| company data drifts into the shared wiki | rule "global carries patterns, local carries data"; machine keys read-only on global repos; a named person submits sanitised copies via PR |
| data leaves through a prompt, a review bot or an alert | decide per data class which exits it may take, before the first connector |
| one company's machine can read another company's repositories | base permission none; one team per company; repositories granted per team |
| a stolen password opens the organisation | two-factor required for every member |
| an integration nobody approved reads every repository | third-party access requires owner approval |
| a pilot dies waiting for corporate IT | first machine outside company infrastructure; bring it in once the pattern works |
| the laptop is the "server" and sleeps at night | a headless machine per company, watched like any node |
| access is handed out by hand forever | move to SSO when the circle grows beyond a handful of people |

## Minimal setup steps

1. Find out whether the group already has a GitHub organisation. Use it, or create one held by
   the holding. Two owners.
2. Work through [templates/github-org-hardening-checklist.md](../templates/github-org-hardening-checklist.md).
3. Create `wiki` ([docs/02](02-llm-wiki.md)) and `agent-registry` ([docs/11](11-agent-registry.md)).
4. Set up your own headless machine (worker user without admin rights, its own agent profile,
   scoped keys — [docs/05](05-worker-delegation.md), [docs/07](07-security.md)).
5. Run your own organisation of agents on it ([docs/13](13-ai-native-organisation.md)) until one
   assignment runs end to end without you as the messenger.
6. Only then: the second machine, in the first company, with [templates/new-entity-onboarding.md](../templates/new-entity-onboarding.md).
