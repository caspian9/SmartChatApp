# Changelog

All notable changes to SmartChatApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
### Changed
### Removed

## [0.0.2] - _in development_

Going-public polish. The repo is being prepared for a public
release; this section collects the changes since 0.0.1 that
make the public tree sane. The actual `v0.0.2` tag will be
cut right before the repo flips to public, after a single
`git filter-repo` pass to flatten the PII residuals out of
history (see
`docs/maintenance/2026-06-08-github-maintenance-review.md`,
"Going-public follow-up: PII in git history").

### Added
- "What this is NOT" section in README, clarifying the
  project's distribution model and scope.

### Changed
- LICENSE copyright holder: `<Your Name or Company>` →
  `SmartChatApp contributors`.
- CI: fail the build on compiler warnings
  (`GCC_TREAT_WARNINGS_AS_ERRORS=YES` on both build and
  test steps).
- Maintenance review checklist synced to the current state
  (13 items moved from `[ ]` to `[x]`).
- Maintenance review narrative scrubbed of literal PII
  references; the description now uses the abstract
  "personal information" phrasing.
- Repository topics on GitHub About: stale `composable-
  architecture` and `tca` topics removed (the project
  never used TCA).
- GitHub Discussions enabled.
- `deleteBranchOnMerge` enabled; merge commits disallowed
  (squash / rebase only).

### Removed
- `docs/superpowers/` design tree moved to the
  gitignored `.claude/superpowers/` (per the maintenance
  review's item #24 decision).
- Maintenance review's literal PII references (`Hai's
  iPhone`, `caspian9` mentions in narrative context).

## [0.0.1] - 2026-06-08

First user-driven release: the maintenance-tier (now / this-week /
release / optional+security) work landed in 18 commits since
the version pipeline in 6858a3f.

### Added
- CI status badge in README.
- `scripts/` and `config/` reference tables in README.
- SECURITY.md and BRANCH_PROTECTION.md.
- THIRD_PARTY_LICENSES.md.
- Issue templates: docs, question; template chooser (`config.yml`).
- CI: `permissions: contents: read`; concurrency control; SPM
  artifact cache keyed on `Package.resolved`; `OPENCLAW_REPO`
  parameter for fork PRs.
- `scripts/bump-version.sh` + `make bump-patch / bump-minor /
  bump-major` (this release).
- `.github/workflows/release.yml` (this release).
- `config/ExportOptions.plist` template (this release).

### Changed
- README tech-stack line corrected: TCA → iOS 17 `@Observable`
  (the codebase never used TCA; the line was stale).
- README roadmap: marked test coverage for `NativeChatViewModel`
  and event-stream handling as done (9 test files).
- README Requirements: Xcode / iOS minimums corrected to match
  what the project + CI actually require.
- CI: three third-party actions pinned to commit SHAs
  (`actions/checkout`, `actions/cache`, `setup-xcode`).

### Removed
- `SmartChatApp/Features/Home/DeviceInfoView.swift` (dead code;
  hardcoded a personal device name; superseded by `HomeView`'s
  `connectionBanner`).

## [0.0.0] - 2026-06-08

Baseline tag, marked *after* the fact. The `MARKETING_VERSION = 0.0.0`
placeholder was set when the version pipeline
(xcconfig + xcodegen + Apple-mandated CFBundleVersion) was added.
Everything in the pre-pipeline history is included in this
initial tag; the [0.0.1] release adds the version-pipeline
itself, the README tech-stack / roadmap / version-floor fixes,
the CI hygiene, the GitHub-maintenance docs, the simulator
matrix, and the AppLogger.redact defense in depth.

### Added
- Native chat UI with per-message bubbles for assistant, thinking,
  tool call, and tool result, with real-time streaming updates.
- Streaming markdown via `MarkdownDisplayView`.
- Interactive cards: music, video, image, button, markdown,
  thinking.
- Multi-gateway profiles (ProfileManager + GatewayProfile).
- Session picker (Gateway → Agent → Channel → Session).
- Per-session message cache (MessageCache) with collapse-state
  cache.
- Node capabilities: `location.get`, `device.status`, `device.info`
  fully implemented; the rest of `node.invoke` commands wired as
  stubs.
- `AppLogger` (OSLog + 2000-line ring buffer; per-category toggles).
- iOS signing xcconfig layer (auto-detect Team ID, local override
  file, idempotent).
- Apple-standard CFBundleVersion pipeline: `Version.xcconfig` +
  `inject-build-timestamp.sh`; `SMARTCHATAPPGitSHA` non-standard
  Info.plist key for dev-only display.
- CI: macos-15 + Xcode 26.3 + xcodebuild build + test.
- Issue / PR templates; CLAUDE.md.

[Unreleased]: https://github.com/caspian9/SmartChatApp/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/caspian9/SmartChatApp/compare/v0.0.0...v0.0.1
[0.0.0]: https://github.com/caspian9/SmartChatApp/releases/tag/v0.0.0
