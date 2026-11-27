# Onboarding a new company (entity) to the group setup

> Template for [docs/12](../docs/12-group-setup.md). One copy per company, kept in the **company's
> local repository** — it lists exactly the data that must not go global. The global wiki gets a
> one-line status per company (onboarded, date, operator role), nothing more.
> Example values in angle brackets.

## Who
| Role | Person | Notes |
|---|---|---|
| sponsor in the company | `<name, role>` | decides what the machine may connect to |
| operator of the headless machine | `<name>` | updates, power, first responder to alerts |
| programme contact (global layer) | `<name>` | grants repository access, reviews pushes to global |

## The machine
- [ ] Always-on machine inside the company network (not a laptop). Host name: `<name>`.
- [ ] Worker user without admin rights; separate admin user for installs ([docs/05](../docs/05-worker-delegation.md)).
- [ ] Agent CLI with its own profile and subscription; non-interactive shells cannot fall back to
      API billing.
- [ ] Deploy keys: read-only for the global `wiki` and `agent-registry`; read-write only for this
      company's own repositories.
- [ ] Live checkout of the agent registry + sync job ([docs/11](../docs/11-agent-registry.md)).
- [ ] Heartbeat and watcher reporting to the group channel ([docs/06](../docs/06-watchdogs.md)).

## Local layer
- [ ] Local repository for company-only knowledge: `<name>` (hosted private, or a bare repo on the
      machine if the data must not leave the network).
- [ ] Connectors the machine may use (mail, files, ERP): `<list>` — each approved by the sponsor.
- [ ] Data that must never go to the global layer: `<list>`.
- [ ] Country- or company-specific rules that deviate from the global ones: `<list, with reason>`.

## Global ↔ local
- [ ] The company's team in the GitHub organisation, with access only to its repositories and read
      access to the global ones.
- [ ] First global-vs-local decision made by the company alone (what goes up, sanitised, via PR).
- [ ] Weekly brief from the company's chief-of-staff agent reaches the programme contact.

## Done when
- [ ] One real assignment ran on this machine end to end without a human passing messages.
- [ ] The five checks of [docs/13](../docs/13-ai-native-organisation.md) passed on a synthetic assignment.

Onboarded: `<date>` · by: `<name>`
