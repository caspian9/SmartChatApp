# Changelog

All notable changes to SmartChatApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1-20260708-01] - 2026-07-08

Maintenance release on the `0.0.1` marketing version. 15
commits since `v0.0.1-20260625-01`, focused on chat
streaming correctness, cache dedup robustness, settings
ergonomics, and CI docs-only branch protection.

### Added
- Chat: `Assistant` and `SlashCommand` metadata-row chips
  on bubbles, resolved through a new
  `MessageBubbleBadgeResolver` that covers the full role
  matrix (PR #33, #42). Two theme tokens added
  (`badgeAssistant`, `badgeSlashCommand`).
- Settings → NativeChat Logs: restructured into a master
  toggle with three sub-toggles — Raw Cache Dump, View
  Render Dump, History Dump — so each dump type can be
  gated independently (PR #38). History-dump lines are
  tagged `[history]` for `grep` extraction from mixed
  `[taskIdStr]` logs.
- Settings: confirmation alert gates the four destructive
  buttons (Clear Session Cache, Clear Message Cache, Clear
  All Caches, Clear Logs) via a new `PendingClearAction`
  enum whose per-case copy names the data at risk
  (PR #30, #31).
- EditProfileSheet: Save / Don't Save / Cancel alert
  guards all three dismiss paths (Cancel toolbar,
  swipe-down on iPhone, outside-tap on iPad) when the form
  has unsaved changes, via a new `ProfileFormSnapshot`
  value type (PR #29, #32).

### Changed
- Cache + Chat: history merge rewritten as append-only;
  user slash commands echoed as `system` bubbles; cache
  entries now carry a time span so cross-bucket dedup can
  absorb clock skew between the device-side streaming
  timestamp and the server's `chat.history.ts` (PR #36, #43).
- Settings + Network: connecting spinner promoted to a
  navigation toolbar item (continuous across scroll, no
  longer torn down by row recycling). `operatorAndNode`
  profiles now connect in parallel via `withThrowingTaskGroup`,
  halving wall-clock connect time and stabilizing the
  toolbar spinner (single `.connecting(role:)` transition).
  New matrix test coverage pins the (non-connecting phase
  × profile role) combinations (PR #35, #41).
- Markdown rendering: third-party `MarkdownDisplayView`
  (TextKit feedback-loop flicker) replaced by a new
  `MarkdownToAttributedString` that walks a `swift-markdown`
  AST and renders via SwiftUI `Text(AttributedString)` —
  no `UIViewRepresentable`, no async `onHeightChange`. Dead
  `MarkdownStreamManager` cache and three dead types in
  `MarkdownCardView.swift` removed. Trade-off: lost fenced
  code-block syntax highlighting and real table rendering.
- CLAUDE.md: freshened after PR #41 (state, command paths,
  privacy usage table) and tightened `.gitignore`
  (PR #46).
- PULL_REQUEST_TEMPLATE: Type of change converted from
  five `- [ ]` checkboxes to five `- **Bold**` bullets so
  the form is metadata, not a task list (a single PR is
  one type; previous layout inflated the per-PR task
  counter confusingly).
- Dependencies: `dorny/paths-filter` 3.0.2 → 4.0.2
  (PR #44, #50), `actions/cache` 5.0.5 → 6.1.0 (PR #45),
  `github/codeql-action/{init,analyze}` 4.36.2 → 4.36.3
  (PR #50).

### Fixed
- `MarkdownCardView`: server single-newline line breaks
  preserved as visible line breaks instead of being
  collapsed to spaces by the CommonMark renderer
  (PR #23, #28). New helper
  `MarkdownTextPreprocessor.preservingSingleNewlines`
  converts lone `\n` to CommonMark hard breaks
  (two trailing spaces + `\n`); paragraph breaks
  (`\n\n`) are untouched. Streaming bubbles were already
  correct (they use SwiftUI `Text(...)`, which preserves
  `\n`); only the post-`lifecycle=end` final-bubble render
  was affected.
- CI: docs-only PRs no longer hang on "Expected — Waiting
  for status to be reported". The `pull_request` `paths:`
  filter was replaced with a `detect-changes` job (uses
  `dorny/paths-filter@v3`); docs-only PRs now get green
  skipped check-runs under the matrix-expanded names
  branch protection requires, without burning the
  30-minute macos-15 build (PR #25).
- CI: a companion `docs-check-status` job runs only for
  docs-only PRs and emits the exact
  `Build & Test (iOS 18 (latest))` /
  `Build & Test (iOS 18 (penultimate))` check-run names
  branch protection keys off (PR #24).
- NativeChat streaming correctness (PR #37, issue #21):
  - Assistant delta handler now runs a 5-branch dispatch
    (seq-guard retransmit drop, exact-dup short-circuit,
    cumulative replace, stale drop, partial-overlap
    rewrite at LCP ≥ 8). Thinking stream mirrors the
    same shape.
  - Chat event `state=final` recovery: server text
    overrides the buggy accumulator.
  - `ChatMessageConverter` routes `role == "thinking"`
    through `content.thinking` (was writing to
    `content.text`); round-trip now produces a thinking
    bubble.
  - Chat-event text routing is skipped when the
    agent-event path is active for the same runId,
    preserving the agent-path-set `startedAt` /
    `endedAt` footer.
  - `lifecycle=end` is marked processed BEFORE any
    `await`, so a WS retransmit of the terminal event
    short-circuits instead of upserting an empty bubble
    over the streamed text.
  - Short suffix-prefix overlap on Chinese-character
    deltas now trims the redundant tail (was producing
    visible "abcabc def" duplication where the streaming
    delta's tail overlapped the running accumulator).
  - Streaming ↔ final transition forces a view-tree
    reset (`.id(state == "streaming" ? ... : ...)`) so
    the streaming `Text` and final `MarkdownCardView`
    paths can't render the same source simultaneously.
  - Assistant stream splits into per-tool-boundary
    bubbles (`<runId>:assistant:<N>`) so tool invocations
    no longer stitch fragments into one Frankenstein
    bubble. Streaming-metadata overlay propagates the
    per-fragment seq so `sortForDisplay` still places
    fragments in chronological order.
- Cache dedup + sort robustness (PR #49):
  - Legacy `stream:"tool"` and modern
    `stream:"item"` / `stream:"command_output"` paths now
    share a per-run `toolCallId → canonical id` alias
    map (exact alias hit, latest-canonical fallback, or
    legacy id itself). Eliminates duplicate
    `toolCall` / `toolResult` bubbles when the server
    emits different ids across paths.
  - Legacy `tool phase=result` no longer clears
    `toolStartedAtByCall`, so the modern `command_output
    (end)` reader still finds the entry — toolResult
    bubble footer now shows both start and end time.
  - Thinking-block dedup: streamed-vs-server assistant
    turn with sibling reasoning now hashes under the
    normalized role, so the server copy collapses onto
    the streaming copy instead of producing two
    bubbles per turn.
  - Thinking is emitted FIRST when the assistant has
    any sibling reasoning block AND a non-thinking main
    entry, regardless of wire order.
  - Replace-on-match dedup: when the server entry is
    richer than the streaming entry (carries `usage`,
    sibling thinking, more content blocks, or — for
    toolResult specifically — significantly more text
    bytes), the server copy replaces the streaming
    entry, keeping the streaming id for
    `CollapseStateCache` compatibility.
  - Fuzzy content-dedup fallback: when strict dedup
    misses, fall back to `role + text` within a 3-minute
    window (narrowed from an earlier 5-minute draft).
  - `toolResult` toolCallId-based fallback: when the
    streaming `command_output (end)` output is
    incremental rather than cumulative, both strict +
    fuzzy content-dedup miss; for `role == "toolResult"`
    we add a third fallback keyed on
    `(toolCallId, toolName, 60s-bucket)`. Server text
    is always authoritative.
  - `command_output` accumulator across phases: delta
    chunks + final `end` are now concatenated with
    suffix-overlap dedup (same pattern as
    `accumulatedAssistantTextByRun`), so the streaming
    toolResult bubble shows the full stdout instead of
    only the last delta chunk.
  - `sortForDisplay` cross-run fallback now prefers
    server-anchored `endedAt` over client `receivedAt`,
    so `command_output end` arriving AFTER `lifecycle
    end` (network jitter) no longer sorts toolResult
    BELOW the assistant final. Structural
    `toolCall < toolResult` tie-breaker added for
    matching `toolCallId` pairs.
  - `toOpenClawChatMessage` persists server `endedAt`
    as `OpenClawChatMessage.timestamp` (when set), so
    the sort recovers after app restart when the
    in-memory `StreamingMetadata` overlay is gone.
    `toolCall` is the exception — keeps its pinned
    start time so the existing
    `toolCall < toolResult` contract holds.

## [Unreleased]

Collected changes since 0.0.1 that have not yet been
tagged as a release. Per project convention, the next
version section (`[x.y.z] - YYYY-MM-DD`) is created
only when the corresponding `vX.Y.Z` tag is cut.

### Added
- "What this is NOT" section in README, clarifying the
  project's distribution model and scope.
- Native chat: slash-command system. Users can type
  `/help`, `/clear`, `/connect`, `/disconnect`,
  `/profiles` for in-chat commands; an autocomplete
  popup appears while typing. Commands dispatch
  locally first and fall through to the gateway
  (via `commands.list`) for server-defined ones
  (PR #22).
- Settings → Chat: "Show thinking" / "Show tool calls"
  toggles to hide per-message bubble chrome for users
  who want a cleaner transcript.
- `make install-remote`: build locally and install on
  a remote iPhone over the network (no USB cable
  needed; PR #19).

### Changed
- LICENSE copyright holder: `<Your Name or Company>` →
  `SmartChatApp contributors`.
- CI: fail the build on compiler warnings
  (`GCC_TREAT_WARNINGS_AS_ERRORS=YES` on both build and
  test steps).
- Release CI: manual codesign path for free personal-
  team `.ipa` so release builds work without an Apple
  ID auth step (PR #16, #15).
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

### Fixed
- `MarkdownCardView`: server single-newline line breaks
  preserved as visible line breaks instead of being
  collapsed to spaces by the underlying CommonMark
  renderer (issue #23). New helper
  `MarkdownTextPreprocessor.preservingSingleNewlines`
  converts lone `\n` to CommonMark hard breaks
  (two trailing spaces + `\n`); paragraph breaks
  (`\n\n`) are untouched. Streaming bubbles were already
  correct (they use SwiftUI `Text(...)`, which preserves
  `\n`); only the post-`lifecycle=end` final-bubble render
  was affected.
- CONTRIBUTING.md: fixed two broken cross-links. The
  `CLAUDE.md` link pointed at `.claude/CLAUDE.md` (a
  gitignored path; the committed file is at the repo
  root); the README link pointed at `#sourcing-openclawkit`
  (an anchor that no longer exists — the current section
  is `Quick Start → 1. Get the code`, anchor `#1-get-the-code`).
  Also updated the "kept under `.claude/`" framing to
  reflect that CLAUDE.md is committed.
- Streaming bubble: three correctness bugs (sequence
  numbers, footer timing, persistence ordering).
- Streaming bubbles: sort by `receivedAt` so the most
  recent message appears at the bottom of the chat.
- Streaming bubble: footer (sequence number + HH:mm →
  HH:mm time range) restored after a regression that
  was dropping it for in-flight messages.
- Streaming pipeline: stable UUIDs across upserts,
  deterministic sort, thinking-block isolation,
  clock-skew tolerance.

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
[0.0.1-20260708-01]: https://github.com/caspian9/SmartChatApp/compare/v0.0.1-20260625-01...v0.0.1-20260708-01
[0.0.1]: https://github.com/caspian9/SmartChatApp/compare/v0.0.0...v0.0.1
[0.0.0]: https://github.com/caspian9/SmartChatApp/releases/tag/v0.0.0
