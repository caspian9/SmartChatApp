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

- [`spec/`](spec/) — original and ad-hoc design docs. Files here may
  predate the current code by a wide margin and are preserved as a
  record of original design intent. See the **Status** notice at the
  top of each file.
- [`superpowers/specs/`](superpowers/specs/) — design specs produced
  by the `brainstorming` skill during feature planning.
- [`superpowers/plans/`](superpowers/plans/) — implementation plans
  produced by the `writing-plans` skill.
