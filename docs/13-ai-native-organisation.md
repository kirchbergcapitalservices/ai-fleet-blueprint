# 13 — Running an AI-native organisation on top of the fleet

The chapters so far describe infrastructure: machines, repositories, locks, gates. This one
describes what people actually want to build on it once they have seen it — **a small
organisation of agents** with a chief of staff, specialists and reviewers, that takes work from
one human lead and multiplies what that person can get done.

We run one. Many teams start the same way: a set of chat projects with named roles. The pattern below is what makes the step from "named roles in
chat windows" to "an organisation that works while you sleep".

## The test that matters

Not "how many agents", not "how many messages". One question:

> **Does the human lead spend fewer minutes on coordination — after counting the time spent
> reviewing, correcting and chasing — while the work gets better?**

Measure it from day one. Take one realistic assignment, run it once by hand and once through the
organisation, and count minutes including review and rework. Without that baseline every later
claim of "it saves time" is a feeling.

## Start with two roles: a chief of staff and an organisation designer

| Role | Does | Does not |
|---|---|---|
| **Chief of staff** (orchestrator) | turns intent into scoped assignments, routes them, tracks status, writes the short weekly brief | do the specialist work itself |
| **Organisation designer** (recruiter) | proposes which specialists the work needs, writes their definitions, reviews the team on a schedule | approve its own proposals — they go through the registry's review like any change |

Give these two your list of what you want to achieve and ask them which specialists the work needs. The
specialist team follows from the work, not from an org chart you drew first. Each new specialist
is a file in the agent registry ([docs/11](11-agent-registry.md)) with an owner, minimal tools and
a named reviewer.

**Where does work enter?** At the start, one front door (the chief of staff) keeps you
from becoming the router. Later, specialists can be called directly for routine work — but every
assignment still lands in the same record, or the organisation loses its memory.

## Work moves as files, not as chat

The step from pilot to organisation is the moment **you stop being the message bus**. In a chat
pilot, you copy the chief of staff's output into the specialist's window, and the specialist's
answer back. That does not scale beyond a handful of handoffs a day, and it cannot run while you
sleep.

| Object | Lives as | Contract |
|---|---|---|
| assignment | a file in the inbox of the **machine** that runs the receiving role ([docs/10](10-code-gates.md), Gate 3 — one inbox per machine, the role is a field in the file) | id, human owner, outcome, numbered requirements `REQ-n`, binding exclusions `NG-n`, closing condition ([template](../templates/worker-brief-template.md)) |
| result | a file under `done/` | assignment id, verdict `DONE` / `PARTIAL` / `BLOCKED` / `FAILED`, evidence per `REQ-n`, what was checked and what was not, next owner |
| decision | an entry in the decision log in the wiki | who decided, which version, scope, date — `proposed` until a human decides |
| lesson | a wiki article or a change to an agent definition | through the normal write path ([docs/02](02-llm-wiki.md)) |

**One dispatcher, one claim per assignment.** Something must make sure each assignment runs
exactly once — a single consumer per inbox that claims, runs, and writes the result. Moving a file
in a synced folder is not a lock; a rename in git is a record, and the exclusion comes from one
consumer process per inbox. Give every side effect (a mail drafted, a file published) its own id
and **check that id at the destination before acting** — an id alone does not stop a retry. The
hard case is a crash after the effect and before the result was written: on restart, look at the
destination first, then decide whether to retry.

## Every author has a reviewer — preferably another model

When an agent says "done", the handoff goes to an **independent reviewer in its own context**
automatically, before you see it. You receive verified results, not first drafts.

- Two passes in the same model already catch more than one. A **different model family** catches
  more again, because it does not share the author's blind spots ([docs/08](08-quality-gates.md),
  [docs/09](09-second-engine-broker.md)).
- Give the reviewer the assignment, the evidence and the output — not the author's opinion of it.
- The best review prompt asks the reviewer to *refute*. Then check the refutations against the
  evidence before acting on them.
- Different models are also good at different jobs. Measure yours: one may be clearly better at
  current market and web research, another at reading scanned PDFs with tables. Let the registry
  record which engine an agent uses and why.

## Humans decide at the action, not at the agent

Gates belong to **actions**, not to roles: sending in someone's name, publishing, filing with an
authority, paying, deleting, granting data access, changing security settings. Factual claims in
anything that leaves the house get verified before it goes ([docs/08](08-quality-gates.md)).
Everything else the organisation may do on its own.

- An approval names **who**, **when** and **exactly what**: the version, the recipients, the
  attachments. The step that executes holds the credentials for the action — the drafting agent
  does not — and checks the approval against what it is about to send. An approval of draft 3
  does not cover draft 4. A prompt that says "ask before sending" is not a gate; a check in the
  executing step is.
- Silence is not approval.

## An integrity line that bypasses the chief of staff

Give one role — an integrity watcher — a direct line to the human lead that does **not** pass
through the orchestrator. It watches for things the organisation should not do (a gate skipped, a
source quoted that does not exist, data in the wrong place) and reports straight up.

Test it like any watchdog ([docs/06](06-watchdogs.md)): plant a known breach and check it arrives.
And make it say **"not checked"** when it could not check — a watcher that reports "clean" after
failing to run is worse than none.

## Private advice stays private

Advisory agents (mentor, coach) are useful. Keep them in a space
only the participants can access, outside the shared memory. If something from a coaching
conversation should reach the organisation, the participant confirms a short summary first. A
prompt cannot keep a secret; only access rights can.

## The organisation is never finished

There is no best practice yet for organisations like this, so treat it like a continuous
improvement board, not a project with an end:

- the organisation designer reviews the team on a schedule ([docs/11](11-agent-registry.md), the
  periodic review) — merge, retire, add;
- every recurring reviewer finding becomes a change to the author's definition;
- new models and new connectors arrive monthly; the registry review is where they get tried.

Rehearse an assignment by hand once to get your baseline — then automate. A swarm of agents
working in parallel is not something you can imitate by copy-pasting; staying manual too long
just slows down the part that makes the difference.

## Reporting up without writing reports

Once the organisation runs, the chief of staff writes the weekly brief anyway. Send it as a
Markdown file to the people who sponsor the programme, or give them read access to the repository
and let them pull it. A five-minute weekly read replaces most status meetings; the conversation
can then be about decisions.

## The five checks before you call it autonomous

Run these on a synthetic assignment before the organisation acts unattended:

1. an approval given for one version is **rejected** for a changed version;
2. the same assignment delivered twice **runs once**;
3. a restart in the middle of an assignment **resumes or fails loudly** — never half-done and silent;
4. a planted breach **reaches the human** without passing through the orchestrator;
5. a check that could not run reports **"not checked"**, never "clean".

Plus the business test from the top: net minutes, measured against your manual baseline.

## Failure modes & guards

| Failure mode | Guard |
|---|---|
| the human lead copies messages between chats all day | assignments and handoffs as files; one dispatcher |
| the organisation grows to dozens of roles nobody uses | organisation designer reviews the team on a schedule; every role has an owner and a reviewer |
| first drafts reach the human | automatic independent review on "done", ideally by another model |
| "approved" covers a later, different version | approval bound to a version and checked by the executing step |
| the orchestrator hides its own failures | integrity watcher with a direct line; tested with a planted breach |
| a failed check reads as a clean bill of health | three states: ok / fail / not checked |
| coaching content leaks into shared memory | separate access; participant confirms any summary |
| "it saves time" with no number behind it | baseline from a manual run; net minutes including review and rework |

## Minimal setup steps

1. Write down what you want the organisation to achieve, and the actions it may **never** take
   alone.
2. Create the chief of staff and the organisation designer in your registry; let them propose the
   first specialists.
3. Set up the inbox and result folders ([docs/10](10-code-gates.md), Gate 3) and one dispatcher
   per inbox on an always-on machine.
4. Pair every author agent with a reviewer; use a second model for the reviewer where you can.
5. Run one assignment by hand, then through the organisation; record the minutes.
6. Pass the five checks on a synthetic assignment before anything runs unattended.
7. Schedule the weekly team review and the weekly brief.
