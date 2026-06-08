# Changelog

All notable changes to SmartChatApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  hardcoded `"Hai's iPhone"`; superseded by `HomeView`'s
  `connectionBanner`).

## [0.0.1] - 2026-06-08

First versioned release. The `MARKETING_VERSION = 0.0.1` baseline
was established when the version pipeline (xcconfig + xcodegen +
Apple-mandated CFBundleVersion) was added; everything in the
pre-pipeline history is squashed under this initial tag.

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
[0.0.1]: https://github.com/caspian9/SmartChatApp/releases/tag/v0.0.1
