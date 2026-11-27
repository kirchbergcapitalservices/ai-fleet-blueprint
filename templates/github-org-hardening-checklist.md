# GitHub organisation — hardening checklist before the first agent connects

> Template for [docs/12](../docs/12-group-setup.md). Menu names and plan coverage change; check
> each item against GitHub's current documentation and your plan before you rely on it. Tick an
> item only after you have looked at the setting, not after you have read about it.

## Ownership
- [ ] The organisation is held by the group (the holding or the programme), not a personal account.
- [ ] **Two** owners. Never one, rarely more than three.
- [ ] Owners use accounts with two-factor authentication and a hardware key or passkey where possible.

## Members and access
- [ ] **Two-factor authentication required** for all members (organisation security settings).
- [ ] Base permission for members: **none**; access is granted per repository via teams. (Internal repositories, if you use them, stay readable to members.)
- [ ] One team per company, plus one small team for the shared repositories.
- [ ] Repository creation by members restricted to what you actually want.
- [ ] Outside collaborators: none, or listed with an end date.

## Apps, tokens and keys
- [ ] Third-party (OAuth) application access restricted — owners approve each app.
- [ ] GitHub Apps installed only by owners, each scoped to the repositories it needs.
- [ ] Fine-grained personal access tokens require owner approval (the default); personal access
      tokens (classic) blocked from organisation resources.
- [ ] Machines use **deploy keys, one key per repository per machine** — no account-wide token on
      a headless machine ([docs/07](../docs/07-security.md)).

## Repositories that drive behaviour (agent registry, scripts)
- [ ] Private.
- [ ] Branch protection / rulesets on `main`: pull request required, also for admins, **plus a
      required check** that passes only with a review proof for the head commit
      ([docs/10](../docs/10-code-gates.md)). On private repositories this needs GitHub Team or higher.
- [ ] Review rules for the review bot written in the repository (`AGENTS.md`) — [docs/10](../docs/10-code-gates.md).
- [ ] Secret scanning and push protection on (for private repositories: the Secret Protection add-on).

## Content repositories (wiki)
- [ ] Private. No branch protection on `main` (multi-writer — [docs/04](../docs/04-multi-writer-git.md)).
- [ ] `log.md merge=union` in `.gitattributes`.

## Later, when the circle grows
- [ ] Single sign-on against your identity provider (SAML SSO is an enterprise-tier feature —
      plan the budget when access widens beyond a handful of people).
- [ ] Audit log reviewed on a schedule; who exported it, when.
- [ ] Decision recorded: stay hosted, or move to a self-hosted GitHub Enterprise Server.

Checked by: `<name>` · on: `<date>` · plan: `<plan>`
