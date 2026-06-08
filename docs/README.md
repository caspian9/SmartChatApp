# SmartChatApp Documentation

## Authoritative (always up-to-date)

These reflect the code as it is today. If they conflict with anything
in this directory, trust these.

- [`../CLAUDE.md`](../CLAUDE.md) — repo instructions and architecture
  overview. Source of truth for component responsibilities, agent
  event stream semantics, and privacy usage descriptions.
- [`../README.md`](../README.md) — user-facing overview, build
  instructions, node capabilities.
- [`../project.yml`](../project.yml) — XcodeGen project configuration.
  The generated `SmartChatApp/Info.plist` and `SmartChatApp.xcodeproj`
  are derived from this file.

## Design docs and implementation plans

Historical and per-feature design work. The filename date is when the
document was written; the content is not edited as the code evolves.

> **Internal design docs are not part of this public repo.**
> Per-feature specs and implementation plans produced during development
> live in the maintainer's local working tree under `.claude/superpowers/`
> (gitignored along with the rest of `.claude/`). The design rationale
> is preserved in commit messages and PR descriptions, so removing the
> directory from the public tree doesn't lose the institutional memory
> — it just stops shipping internal-thinking documents with the released
> code. See `docs/maintenance/2026-06-08-github-maintenance-review.md`
> (item #24) for the policy decision.
