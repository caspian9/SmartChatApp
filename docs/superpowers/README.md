# `docs/superpowers/` — internal design and planning docs

This directory contains design specs and implementation plans
written during feature development. They are **internal thinking
documents**, not user-facing documentation.

## Personal-information policy

These documents may reference:

- Personal device names (e.g. an iPhone's `Settings → General →
  About → Name` field, which defaults to the owner's first
  name)
- Apple Developer account Team IDs
- Internal URLs (gateway hostnames, local file paths)

Before the repository is made public:

1. Grep for personal device names: `grep -rE "Hai's iPhone" docs/`
2. Replace with `<Your iPhone>` or a generic placeholder.
3. Do NOT move this directory to a gitignored tree unless the
   project also needs to stop referencing the design rationale
   in commit messages — the design doc history is part of the
   project's institutional memory.

## Index

See `../README.md` for the top-level docs index.
