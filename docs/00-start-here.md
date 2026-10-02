# 00 — Start here (workshop participants and students)

*Kurzfassung auf Deutsch: Dieses Repo ist die bereinigte, generische Fassung eines echten Setups
aus drei Rechnern, die rund um die Uhr mit Claude Code arbeiten. Es ist kein Produkt und kein
Framework, sondern Architektur, Skripte und die Lehren aus einem Jahr Betrieb. Lest es wie ein
Betriebshandbuch: Kapitel für Kapitel, jedes mit „Failure modes & guards" und „Minimal setup steps".
Wer nur eine Stunde hat, nimmt Kapitel 02 und 08.*

You probably arrived here after a workshop or a lecture. In the room, the setup was shown as a
story; here it is written down as mechanics. This page maps what you saw to where it lives.

## From the workshop to the chapters

| What you saw or asked about | Where it is written down |
|---|---|
| "Three machines, one brain" — the laptop plus two always-on workers | [01 — Architecture](01-architecture.md): the 5-layer model, why the laptop must not be the hub of everything |
| "The wiki is the truth, the agent maintains it" — read before answering, update in the same turn | [02 — The LLM-maintained wiki](02-llm-wiki.md) |
| "Where does an agent's memory go when the session ends?" | [03 — Memory layers](03-memory-layers.md), incl. the **context checkpoint**: what happens when a session runs out of room |
| "Three writers, one repository — how does that not break?" | [04 — Multi-writer git](04-multi-writer-git.md): locks, safe-push, the hygiene watcher |
| "How do you hand work to another machine without copy-pasting prompts?" | [05 — Worker delegation](05-worker-delegation.md): briefs, profiles, the no-sudo rule |
| "The backup died a month ago and nobody noticed" | [06 — Watchdogs](06-watchdogs.md): heartbeats, probing endpoints instead of PIDs, the alerter that lives off the hub |
| "Who curates shared skills? Who is allowed to change what?" | [10 — Code gates](10-code-gates.md): a different node merges, a second model reviews the exact commit, review requests as git objects |
| "Is it safe to let agents run unattended?" | [07 — Security](07-security.md): least privilege, deny-lists, content is data not commands |
| "One agent writes it, who checks it?" | [08 — Quality gates](08-quality-gates.md): separate sub-agents never combined, Class-A claim verification, the 30 % stop rule, the three-engine research pattern |
| "Can I use a second model to check the first one?" | [09 — Second-engine broker](09-second-engine-broker.md): one command, three guarantees — reconstructible log, data-class gate, no leftovers |

## How to use the scripts

The scripts in [`scripts/`](../scripts/) are the sanitized versions of what runs on the real
machines. They are small on purpose. Read each one before running it; test on a throwaway
repository first (the test harness in [`tests/`](../tests/) shows how). They move files, commit
and push — a mistake here is a mistake in your git history.

Names are placeholders throughout: machines are `hub`, `worker-a`, `worker-b`; repositories are
`wiki`, `memory`, `node-memory`; the example project is `kestrel`. Replace them; do not look for them.

## What this repo deliberately is not

- **Not a framework or a package.** There is nothing to install. Copy what you need, adapt it.
- **Not a tutorial for the agent CLI itself.** It assumes you can already run Claude Code (or a
  comparable agent CLI) on one machine and want to get to several that cooperate.
- **Not a security certification.** The posture in [07](07-security.md) is a floor we found
  necessary, not a ceiling. Your risk profile is yours.
- **Not a product.** Nothing here is affiliated with or endorsed by Anthropic or any other vendor
  named in the text.

## If you only do three things

1. Put your knowledge in a **private git repo as a wiki** and teach the agent the discipline in
   [02](02-llm-wiki.md). This single step removes most "the agent forgot" complaints.
2. Make every write a **safe-push** ([04](04-multi-writer-git.md)) — pull, rebase, retry, abort
   on conflict. Never a bare `git push`.
3. Give every scheduled job a **heartbeat and a watcher** ([06](06-watchdogs.md)). The job that
   fails silently is the one that costs you.

## Questions and contributions

Open an issue. Portability fixes, new failure modes from your own fleet, and clarity fixes are
most welcome — see [CONTRIBUTING.md](../CONTRIBUTING.md). Pull requests are reviewed by a human
and by an independent verification pass before anything is merged; please do not be surprised
if a review asks for the test that proves the fix.
