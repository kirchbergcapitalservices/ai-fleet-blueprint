# 08 — Quality Gates for Agent Output

An agent that produces confident, fluent, *wrong* output is worse than one that
crashes — because it looks finished. In a fleet doing research, drafting, and
analysis, the failure that costs you is not a stack trace. It's a plausible
fabricated fact that sails through unchecked and lands in front of a client, an
investor, or a lawyer.

Quality gates are the checkpoints that stop that. The theme: **nothing
irreversible or external leaves the fleet without passing an independent check.**

## Why a single agent isn't enough

Ask one agent to research a topic *and* judge its own work, and you get
**confirmation bias at machine speed.** The same model that generated a claim is
the least able to doubt it — it already "believes" it. Single-agent research
reliably produces answers that are internally coherent and externally wrong,
stated with total confidence.

| Single-agent research               | Why it fails                              |
| ----------------------------------- | ----------------------------------------- |
| generate + self-check in one pass   | the checker shares the generator's blind spots |
| "does this look right to me?"       | it always looks right to its own author   |
| confidence as a proxy for accuracy  | fluency is uncorrelated with truth        |

The fix is not a better prompt. It's **structural independence** — separate the
generating from the checking so a fresh perspective can catch what the author
can't.

## The multi-agent pattern: independent, never combined

We split work into **separate sub-agents, one per role, each running its own
independent pass.** A researcher gathers. A different agent — with no stake in
the first one's conclusions — critiques. A third verifies facts. Crucially, we
**never combine roles into one pass.**

| Combined pass (avoid)                 | Separate independent sub-agents (use)        |
| ------------------------------------- | -------------------------------------------- |
| "research and critique this"          | agent A researches → agent B critiques        |
| one agent wearing two hats            | each hat is a fresh context, no shared bias   |
| editor + reviewer in a single prompt  | editor pass AND reviewer pass, run apart      |

This is not theoretical. In our own audits, a **combined** editor-plus-reviewer
pass repeatedly found **zero** critical issues across several document versions
— while running the *same two roles as separate sub-agents* surfaced multiple
critical issues in a single version. When you fuse roles, they cancel: the pass
optimizes for a coherent-sounding single voice instead of an adversarial catch.
Keep them apart.

```
   ┌───────────┐   ┌────────────┐   ┌────────────────┐
   │ Researcher│ → │  Critic    │ → │ Claim-verifier │ → gate
   │ (gathers) │   │(independent│   │ (primary-source│
   └───────────┘   │  critique) │   │   check)       │
                   └────────────┘   └────────────────┘
     each box = a fresh sub-agent, no shared conclusions
```

## The claim-verifier pass for Class-A claims

Some claims are checkable against ground truth, and those are exactly the ones
that destroy credibility when wrong. We call them **Class-A claims** and require
a dedicated verification pass — against **primary sources** — before anything
built on them goes external.

| Class-A claim type          | Verify against                         |
| --------------------------- | -------------------------------------- |
| identifiers (patent #, IDs) | the primary registry / official record |
| citations (papers, DOIs)    | the actual source document             |
| statistics / numbers        | the cited dataset or paper             |
| named third-party facts     | an authoritative independent source    |

The rule: the verifier **re-checks each Class-A claim against the primary
source**, not against the generating agent's summary of it. And it has teeth — a
concrete stop condition:

> If more than ~30% of sampled Class-A claims fail verification, **STOP.** The
> document is not fixable claim-by-claim; the whole thing is untrustworthy and
> goes back for a rebuild.

A high fabrication *rate* means the generator was hallucinating structurally, so
you can't trust even the claims that happen to check out. The gate is not "fix
the bad ones" — it's "reject the batch."

## War stories (anonymized)

Two real incidents, names and numbers removed, that shaped these gates:

> **The invented identifiers.** An audit agent produced a polished analysis
> citing six official identifiers. A verification pass checked each against the
> primary registry — **four of the six did not exist.** The agent had
> pattern-matched plausible-looking numbers into being. Without the verifier
> pass, a document with fabricated identifiers would have reached an external
> lawyer. The claim-verifier caught it at the gate. This is *why* the >30%-fail
> stop rule exists — that batch was ~67% fabricated.

> **The confident summary.** A single research agent summarized a set of studies
> and drew a clean conclusion. An independent critic sub-agent, run separately,
> found the conclusion rested on one study the researcher had *mis-read* — the
> paper said the opposite. A combined "research-and-review" pass had earlier
> waved the same conclusion through. Two independent passes; one caught what the
> fused pass could not.

The lesson both times: **the check has to be independent of the thing it
checks.** Self-review and fused roles produce false confidence.

## Fact-gates for outbound messages

A verifier pass on a document is great — but the risky moment is *transmission*.
So there's a distinct gate right before anything leaves: **no outbound message
containing Class-A claims goes out until those claims are verified.**

| Outbound artifact              | Gate before it sends                        |
| ------------------------------ | ------------------------------------------- |
| email with numbers / citations | fact-gate: verify every Class-A claim first |
| a client-facing summary        | fact-gate + human sign-off                  |
| an internal note (no claims)   | lighter — no external exposure              |

The gate is placed at the boundary, not just at authoring time, because a claim
can be introduced, edited, or corrupted anywhere between draft and send.

## Score-caps by source tier

Not all sources deserve equal weight, and an agent left alone will happily treat
a random blog and a primary registry as equally authoritative. We cap how much
confidence a claim can earn by the **tier of its best source.**

| Tier | Source kind                          | Confidence cap        |
| ---- | ------------------------------------ | --------------------- |
| T1   | primary/official record, registry    | may reach high        |
| T2   | reputable secondary, peer-reviewed   | moderate–high         |
| T3   | general press, aggregators           | capped at moderate    |
| T4   | unverified / anonymous / blog        | capped low; flag it   |

A claim supported only by a T4 source **cannot be scored as high-confidence**,
no matter how fluently it's written. This stops the classic failure where
confident prose about a weak source gets treated as established fact.

## Human sign-off for the irreversible

The last gate is a person. Anything **irreversible or external** — sending to a
third party, publishing, filing, dispatching to an authority — requires an
explicit **human sign-off.** Agents draft; humans commit the irreversible act.

| Action                          | Gate                                   |
| ------------------------------- | -------------------------------------- |
| draft / analyze / summarize     | agent, autonomous                      |
| internal commit to shared repo  | agent, within its scope                |
| **send to a third party**       | **human sign-off**                     |
| **publish / file / dispatch**   | **human sign-off**                     |

The dividing line is *reversibility*. A wrong internal draft is edited and
forgotten. A wrong email to a client, or a wrong filing to an authority, cannot
be recalled. For those, the machine stops and asks. If an agent is ever unsure
whether an action crosses the line — it treats it as if it does, and escalates.

## Failure modes & guards

| Failure mode                                   | Guard                                          |
| ---------------------------------------------- | ---------------------------------------------- |
| Agent confidently fabricates a fact             | independent claim-verifier vs. primary source  |
| Self-review rubber-stamps the author's errors   | separate sub-agents; never combine roles        |
| Editor + reviewer fused → catches nothing        | run editorial and review as separate passes     |
| Fabricated identifiers reach an external party   | Class-A verification + >30%-fail STOP rule      |
| Bad claim slips in between draft and send        | fact-gate at the outbound boundary              |
| Weak source treated as authoritative             | score-caps by source tier (T1–T4)              |
| Irreversible external action taken by an agent   | human sign-off gate for anything external       |
| Agent unsure whether an action is reversible     | default to "it is irreversible," escalate       |

## Minimal setup steps

1. **Split roles into separate sub-agents** — researcher, critic, verifier —
   and **never combine** them in one pass.
2. Define your **Class-A claims** (identifiers, citations, numbers, named
   third-party facts) and give them a **verifier pass against primary sources.**
3. Adopt a hard **stop rule**: high fabrication rate → reject the batch, don't
   patch it.
4. Put a **fact-gate at the outbound boundary**, not just at authoring time.
5. Apply **source-tier score-caps** so weak sources can't earn high confidence.
6. Require **human sign-off for anything irreversible or external**; agents draft,
   humans dispatch.
7. When an agent is unsure a claim is verified or an action is reversible, make
   the default **stop and escalate.**

Fluent and wrong is the enemy. Build the gates so that *independent* checks — not
the author's own confidence — decide what leaves the fleet.
