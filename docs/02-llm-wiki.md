# 02 — The LLM-maintained wiki

> The single most valuable artifact in a multi-agent fleet is not the agents. It's the
> wiki they read before they answer and write after they learn. Everything else is
> plumbing.

## Why a wiki, and why the LLM maintains it

Most people start an agent project by dumping notes into a chat, a scratch file, or a
growing `NOTES.md`. This works for a week. Then the same question gets a different answer
on Tuesday than it got on Monday, because the relevant fact was three scrollbacks up in a
conversation nobody kept. Scattered notes are write-optimized and read-hostile.

A wiki inverts that. It is **read-optimized**: one canonical place, one article per
concept, addressable by a stable name. The twist in a fleet is that the *LLM itself* is
the librarian. Humans do not hand-curate it. Every agent that learns something durable is
responsible for folding that knowledge back into the wiki — atomically, immediately,
before it moves on. This is the Karpathy-style "LLM maintains its own knowledge base"
approach: the model reads the wiki to ground its answers, and edits the wiki to record
what it discovered.

The payoff is compounding. Note piles decay; a maintained wiki appreciates. Answer N
benefits from every insight harvested during answers 1…N-1, regardless of which node or
which session produced them.

## Two data structures, not one

The wiki is really two coupled stores with opposite mutability rules.

| Store | Mutability | Holds | Optimized for |
|---|---|---|---|
| **The wiki** (articles) | Mutable — edit in place | Current best understanding of each concept | Reading / grounding answers |
| **The log** (append-only) | Immutable — only append | What was learned, when, by whom, why the wiki changed | Audit, provenance, "how did we get here" |

The wiki answers *"what is true now?"*. The log answers *"what did we learn and when?"*.
Keep them separate. The instinct to make one file do both jobs produces a document that
is neither readable nor auditable. When an article changes, you rewrite the article **and**
you append a one-line entry to the log. The article stays clean; the history lives next
door.

## The article schema

Every article is one atomic concept, front-matter first, body second.

```markdown
---
title: Rate limiting on the ingest API
slug: rate-limiting-ingest-api
status: stable          # draft | stable | deprecated
owner: worker-a         # which node curates this article
updated: 2025-03-14
tags: [api, ingest, limits]
links: [ingest-pipeline, retry-policy]   # slugs of related articles
---

## Summary
One paragraph a reader can stop after and still be correct.

## Detail
The substance. Tables over prose where it fits.

## Gotchas
The things we learned the hard way.

## See also
- [[ingest-pipeline]]
- [[retry-policy]]
```

**Atomic** means one concept per file. If an article needs an "and" in its title, it's
probably two articles. Small articles cross-link cleanly, get found by search, and can be
edited without merge pain. A 2,000-line mega-page is where knowledge goes to become
unfindable.

## The read-before-answering rule

This is the rule that makes the wiki worth maintaining. **Before an agent answers a
non-trivial question in a wiki's domain, it reads the relevant articles first.** Not its
own memory of them — the current file. Memory is stale by construction; the file is
ground truth.

Concretely, an agent's loop for a domain question is:

1. Resolve which article(s) the question touches (search by slug/tag).
2. Read them.
3. Answer, grounded in what it just read.
4. If it learned something the articles don't yet capture → run the post-insight sequence.

Skipping step 2 is how a fleet drifts. Two agents "remember" the same policy differently,
both answer confidently, and now you have a contradiction with no arbiter. Reading the
file first means the file is the arbiter.

## The mandatory post-insight sequence

Whenever an agent produces a **durable, generalizable insight** — a fact that will still
matter next week and isn't specific to one throwaway task — it must run this sequence
before ending the turn. Non-optional; this is what keeps the wiki alive.

| Step | Action | Why |
|---|---|---|
| 1 | **Locate** the article the insight belongs to (or decide a new one is needed) | Prevent duplicates; one concept, one home |
| 2 | **Read** the current article | Edit against reality, not memory |
| 3 | **Fold in** the insight — edit the article in place, keep it atomic | Wiki stays current |
| 4 | **Cross-link** — add `[[slug]]` links to/from related articles | Knowledge stays navigable |
| 5 | **Append to the log** — one line: what changed, why, which article | Provenance without polluting the article |
| 6 | **Lint** — front-matter present, title unique, links resolve | Catch rot at write time |
| 7 | **Bump `updated`** in front-matter | Staleness is visible |

The discipline is: *insight is not "done" until it's in the wiki.* An insight that lives
only in a finished chat is an insight you will pay to rediscover.

## Cross-linking

Links are what turn a folder of files into a knowledge graph. Two directions matter:

- **Forward** — "to understand this, also read X." Put these in `See also`.
- **Backward** — when you add article Y that relates to existing X, add a link from X to Y
  too. One-way links rot; the reader landing on X never learns Y exists.

Use `[[slug]]` wikilinks freely, even to articles that don't exist yet. A dangling
link is not an error — it's a to-do marking a concept worth writing up later.

## Lint rules

Cheap, mechanical checks run on every write keep the wiki from decaying:

| Rule | Fails when |
|---|---|
| Front-matter present | Missing `title`, `slug`, `status`, `updated` |
| Slug unique | Two files claim the same slug |
| Title ↔ filename agree | Renamed one, forgot the other |
| Links resolve | `[[slug]]` points at nothing (warn, don't block) |
| One concept | Article exceeds a soft size cap → split candidate |
| `updated` is fresh-ish | `status: stable` but `updated` is months old → review flag |

## Keeping the log and the wiki honest over months

Three mechanics that were missing in the first year and that we now consider part of the discipline:

| Mechanic | Rule | Why |
|---|---|---|
| **Monthly log rotation** | `log.md` carries the current month; finished months move **byte-identical** to `log/YYYY-MM.md` on the 1st, by one scheduled job on one node. History is searched with `grep -r … log.md log/` | an append-only file that grows forever becomes unreadable and slow to diff; rotation keeps append-only *and* keeps it usable — move, never edit |
| **Nightly lint on a worker** | orphan check (index ↔ disk), dead links, articles older than 90 days without a `stale` flag; a message only on **delta**, never a daily "all green" | a lint that reports every night is ignored in a week; a lint that reports changes gets read |
| **The log belongs to `main`** | `log-append.sh` refuses to append on a feature branch: it writes through a throwaway worktree off `origin/main`, or spools the entry to a local file and tells you — it never silently puts a log entry on the wrong branch | two sessions shared one clone; one switched branches, two log entries landed on a feature branch and vanished from the history everyone reads |

## Enforcement, not appeal — four more mechanics

| Mechanic | Rule | Why |
|---|---|---|
| **A master index with an orphan gate** | one `index.md` lists every article with a one-line hook; our wiki's write wrapper — a few lines around the generic safe-push helper shipped here, roughly `for f in "$@"; do case $f in wiki/*.md) grep -qF "($f)" index.md \|\| { echo "$f not in index.md"; exit 1; }; esac; done` — **refuses to commit a new article without an index line**; a nightly lint reports index entries without a file and files without an entry | 170 of 598 articles were once invisible to the index — and therefore to every agent that read the index first. An unindexed article is a rumour |
| **The lint gate lives in the write wrapper** (yours to add on top of `git-safe-commit-push.sh`; the generic helper in this repo is content-agnostic) | not in a pre-commit hook: `.git/hooks` is never cloned, so a hook-based gate exists in one clone and is an assumption in the others ([docs/04](04-multi-writer-git.md)) | "a lint rule without an executable checker is a statement of intent" |
| **Bump the header in the same commit** | the freshness check reads `updated:` in the article header first and the git date only as fallback | 17 headers once lied about their date; a header that lies makes the freshness check blind. The fix was the headers, not the check |
| **`log.md merge=union`** in `.gitattributes` (and the rotated `log/*.md`) | two machines appending at the same moment *always* collide at the same place — the end of the file; union merge keeps both entries, order inside a log does not matter | without it, every concurrent append ends in a rebase conflict with one entry stranded locally — the *normal* case with three writers, not an edge case |

One header format across the repo — articles and templates alike. This repo shows YAML
front matter; pick yours and lint for it.

## Two rules about negative statements

The wiki is where "X does not exist", "Y is gone", "node Z is clean" get written — and those
sentences fail differently from positive ones. A positive claim breaks visibly when the world
changes. A negative claim **goes quietly untrue**, and the next confirming glance turns it into a fact.

1. **Date it, scope it, sign it.** "Checked as `<user>` via `<path>` on `<date>`: no such file under `$HOME`." A `~`-path without the user is not a statement — `~` is user-relative, and on macOS the launchd domains of two users do not see each other.
2. **Past tense, never present as a permanent state.** "Was not present on 22.07." expires cleanly; "is not operable" does damage four weeks later. Dating alone is not enough — the tense is the difference.

And the companion rule for the agent writing it: **an absence claim needs a positive control in the
same message** — a known-present case that the same search *did* find. A search that returns zero
for everything is not evidence of absence; it is evidence of a broken search. An unreachable node is
not "no drift"; it is *unchecked*. In one audit of our own documentation, fifteen false statements
about two nodes were found — **every one** claimed a node could do *less* than it could. That direction
never shows up by failing, only by nobody trying.

## Failure modes & guards

| Failure mode | Symptom | Guard |
|---|---|---|
| **Scattered-notes relapse** | Insights land in chat/scratch files, never the wiki | Post-insight sequence is mandatory, not "when I remember" |
| **Answer-from-memory** | Agent contradicts the article it never re-read | Read-before-answering as a hard step in the loop |
| **Mega-articles** | One file owns ten concepts, unsearchable | Atomicity lint + soft size cap → split |
| **One-way links** | Reader on X never discovers related Y | Add the backlink when you add the forward link |
| **Wiki as changelog** | Article body clogged with "on Tuesday I changed…" | History goes in the append-only log, never the article |
| **Silent staleness** | `stable` articles quietly go wrong | `updated` front-matter + freshness lint surface it |
| **Duplicate concepts** | Same idea, two slugs, drifting apart | Step 1 (locate before create) + slug-uniqueness lint |

## Minimal setup steps

1. **One repo, two trees**: `wiki/` (mutable articles, one file per concept) and
   a single append-only `log.md` at the repo root (written only via
   `scripts/log-append.sh`; split into monthly files later if it grows huge).
2. **Adopt the article schema** — front-matter template above, checked in as a
   `_template.md`.
3. **Write the read-before-answering rule into every agent's instructions.** This is the
   load-bearing sentence.
4. **Write the post-insight sequence into every agent's instructions.** Insight → wiki,
   before turn end.
5. **Add the linter** as a pre-commit / pre-write check — front-matter, unique slug,
   resolving links.
6. **Seed a handful of articles by hand** so agents have a shape to imitate, then let the
   fleet maintain it.

The wiki beats scattered notes for one structural reason: notes optimize the moment of
writing; a maintained wiki optimizes every future moment of reading. In a fleet where
"every future moment" is spread across many agents and many sessions, that trade is not
close.
