## Summary

One- or two-sentence description of what this PR changes.

## Type of change

(Bold the applicable type and delete the rest. This is
metadata, not a checklist item — it's intentionally not
a `- [ ]` list because the five options are mutually
exclusive and only one applies per PR.)

- **Bug fix** (non-breaking change that fixes an issue)
- **New feature** (non-breaking change that adds functionality)
- **Breaking change** (fix or feature that would cause existing functionality to change)
- **Documentation update**
- **Refactor** (no functional change)

## What changed

- Bullet 1
- Bullet 2

## How to test

Steps for a reviewer to verify this works:

1. Build with `make build`
2. ...
3. Expected result: ...

## Prerequisites

- [ ] The `../openclaw` sibling is present at the expected path
      (see README → Quick Start → 1. Get the code). CI clones it automatically
      from `caspian9/openclaw`; local builds need it on disk.
- [ ] `make configure-signing` succeeded (or `IOS_DEVELOPMENT_TEAM`
      is set in the environment).

## Screenshots / Logs

If applicable, attach screenshots or relevant log lines.

## Checklist

- [ ] `make build` succeeds locally
- [ ] `xcodebuild test -scheme SmartChatApp` passes (or notes why tests aren't applicable)
- [ ] New or modified `NS*UsageDescription` entries added to `project.yml` if the change touches a privacy-protected API
- [ ] Commit messages follow the existing `feat:` / `fix:` / `docs:` / `refactor:` style
- [ ] History was not rewritten (no force-push needed)
