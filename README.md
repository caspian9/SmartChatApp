# SmartChatApp

**iOS chat client for [OpenClaw Gateway](https://github.com/openclaw/openclaw) — native streaming, per-message cards, and on-device node capabilities.**

[![CI](https://github.com/caspian9/SmartChatApp/actions/workflows/ci.yml/badge.svg)](https://github.com/caspian9/SmartChatApp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![iOS 18.0+](https://img.shields.io/badge/iOS-18.0%2B-blue.svg)](https://developer.apple.com/ios/)

> **Status:** early development (v0.0.1). See [CHANGELOG.md](CHANGELOG.md) for the most recent changes.

<!-- Hero image: drop a screenshot or animated GIF at docs/hero.png. This is the single biggest conversion lever for an iOS project. Until then the README shows text only. -->

## Contents

- [Why SmartChatApp?](#why-smartchatapp)
- [Screenshots](#screenshots)
- [What this is NOT](#what-this-is-not)
- [Features](#features)
- [Quick Start](#quick-start)
- [Comparison](#comparison)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Node Capabilities](#node-capabilities)
- [Privacy Usage Descriptions](#privacy-usage-descriptions)
- [Versioning](#versioning)
- [Build scripts](#build-scripts)
- [Build configuration](#build-configuration)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Why SmartChatApp?

[OpenClawKit](https://github.com/openclaw/openclaw) ships a generic
`OpenClawChatView` that handles a single-stream agent output as one
bubble. For most agentic use cases — thinking, tool calls, command
output, results arriving in their own event streams — that view
loses the structure: a tool call and a tool result look the same,
markdown rendering doesn't get incremental updates, and there's no
way to plug in interactive cards (music, video, image, button).

SmartChatApp is the consumer app we wanted to exist: it pairs
OpenClawKit with a per-message bubble renderer that knows the agent
event types, an interactive card system for non-text content, and a
Node command bridge that lets the gateway invoke on-device
capabilities (location, device status, camera stubs).

If you're building a custom chat surface on top of OpenClawKit and
need per-message rendering, SmartChatApp is a working reference. If
you just need a generic chat UI, use `OpenClawChatView` from
OpenClawKit directly.

## Screenshots

<!--
  Drop screenshots / GIFs in docs/ and link them here. Suggested
  captures (in priority order):
  1. NativeChatView streaming a multi-step agent run (assistant +
     tool call + tool result in one screenshot)
  2. MusicCardView with a playing track
  3. SessionPickerView with multiple profiles
  4. SettingsView's profile list + connect button
-->

_Screenshots are not part of the public tree yet. The maintainer
will add them before flipping the repo to public._

## What this is NOT

To set expectations clearly:

- **Not an App Store app.** SmartChatApp is distributed via
  GitHub Releases as a sideloadable `.ipa`. There is no
  TestFlight lane, no App Store Connect integration, and no
  code-signing identity for distribution in the repo.
- **Not a chat SDK or library.** The native chat surface is a
  *consumer* of [OpenClawKit](https://github.com/openclaw/openclaw);
  if you want to embed a chat UI in your own iOS app, use
  OpenClawKit directly. SmartChatApp's contributions are the
  per-message renderer and the Node command bridge, and they
  are coupled to the iOS app shape.
- **Not production-ready.** The app is in early development.
  Expect rough edges: the version pipeline is new, the
  stubbed node capabilities return `ok: true` without doing
  anything, and the agent event stream mapping in
  `NativeChatViewModel` is calibrated for a specific gateway
  version. Pin your gateway commit when you need stability.
- **Not a multi-gateway chat platform.** It works against one
  OpenClaw Gateway at a time, selected by
  [Profile](https://github.com/caspian9/SmartChatApp/blob/main/SmartChatApp/Features/Settings/).

## Features

- **Native chat UI** — Per-message bubbles for assistant, thinking,
  tool call, and tool result, with real-time streaming updates.
- **Streaming markdown** — Incremental updates via
  [MarkdownDisplayView](https://github.com/zjc19891106/MarkdownDisplayView).
- **Interactive cards** — Music, video, image, button, markdown, and
  thinking content.
- **Multi-gateway profiles** — Switch between any number of
  OpenClaw Gateway instances, with TLS and token auth per profile.
- **Session picker** — Drill down Gateway → Agent → Channel → Session
  in a single header strip.
- **Per-session message cache** — Local persistence with
  collapse-state cache for long-history handling.
- **Node capabilities** — `location.get`, `device.status`,
  `device.info` fully implemented; canvas, camera, photos,
  contacts, calendar, reminders, talk, screen, and system
  commands wired as stubs ready for real implementations.

## Quick Start

The fastest path from `git clone` to a running build is ~10
minutes on a clean machine (plus a one-time OpenClaw Gateway
setup if you don't have one yet).

### 1. Get the code

```bash
git clone https://github.com/caspian9/SmartChatApp.git
cd SmartChatApp

# SmartChatApp is sibling-linked to an OpenClawKit fork.
# Clone the fork into the sibling position the project expects:
git clone https://github.com/caspian9/openclaw.git ../openclaw
```

The `../openclaw` layout is required — `project.yml` path-links
OpenClawKit at `../openclaw/apps/shared/OpenClawKit/`. CI clones
this automatically; locally you must do it yourself. See
[CONTRIBUTING.md → Before you start](CONTRIBUTING.md#before-you-start)
for the workspace diagram.

### 2. Build

```bash
# Generate the Xcode project (XcodeGen reads project.yml)
xcodegen generate

# Build and install on the first connected iPhone
make install

# — or —

# Build only (no device install)
make build

# List connected devices
make list-devices
```

`make build` auto-runs `scripts/ios-team-id.sh` to detect your
Apple Developer Team ID and writes it into the git-ignored
`config/.local-signing.xcconfig`. Override manually via
`config/LocalSigning.xcconfig` (see the `.example` template).

### 3. Connect to a gateway

The app needs an [OpenClaw Gateway](https://github.com/openclaw/openclaw)
instance to talk to. The fastest local path is to run the gateway
on the same Mac (`docker run ...` from the OpenClaw repo's README);
once it's listening, open SmartChatApp → Settings → Add Profile,
point at `localhost:18789` (or whatever your gateway uses), and
tap **Connect**.

### Requirements

- macOS with **Xcode 16.4** (project local) / **Xcode 26.3** (CI to
  match the OpenClawKit sibling's `swift-tools-version: 6.2`)
- iOS **18.0** deployment target
- A connected iPhone for device builds (or use `make compile-only`
  to skip the install step)
- An [OpenClaw Gateway](https://github.com/openclaw/openclaw)
  instance to connect to

## Comparison

|                                  | SmartChatApp | OpenClawChatView (SDK) | OpenClawChatUI (SDK) |
|----------------------------------|--------------|------------------------|----------------------|
| Per-message bubble types         | ✅ thinking / tool / toolResult | ❌ single bubble | ⚠️ minimal |
| Card system (music / video / etc.) | ✅ 6 card types | ❌ | ❌ |
| Streaming markdown               | ✅ incremental | ⚠️ re-render on each delta | ⚠️ same |
| Node command bridge              | ✅ 11 commands | ❌ | ❌ |
| Multi-gateway profile switching  | ✅ UserDefaults-backed | n/a | n/a |
| Easy to embed in another iOS app | ❌ (app shape) | ✅ (UIKit + SwiftUI views) | ✅ |
| Maintained                       | ✅ this repo | ✅ OpenClawKit | ✅ OpenClawKit |

Pick the row that matters to you: per-message types, cards, or
Node bridge → SmartChatApp. Drop-in generic chat UI → use
OpenClawKit's `OpenClawChatView` directly.

## Tech Stack

- **SwiftUI** for the UI
- **iOS 17 Observation** (`@Observable` + `@MainActor`) for state
  management
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** for the
  project file (also the source of truth for `Info.plist`)
- **[OpenClawKit](https://github.com/openclaw/openclaw)**
  (path-linked from `../openclaw`) for the gateway protocol and
  chat UI
- **[MarkdownDisplayView](https://github.com/zjc19891106/MarkdownDisplayView)**
  for streaming markdown rendering

## Project Structure

```
SmartChatApp/
├── App/                       # @main entry
├── Core/
│   ├── Models/                # GatewayProfile
│   ├── Network/               # SessionManager, GatewayClient, GatewayChatTransport
│   ├── NodeHandlers/          # NodeCommandRouter + per-capability services
│   │                          #   (LocationService, DeviceService — real;
│   │                          #    canvas/camera/photos/contacts/calendar/
│   │                          #    reminders/talk — stubs)
│   └── Services/              # CardRegistry, ProfileManager, ConfigurationManager,
│                              # SessionCache, MessageCache, MarkdownCache,
│                              # MarkdownStreamManager, CollapseStateCache
├── Features/
│   ├── Chat/                  # SDK chat view (OpenClawChatUI wrapper)
│   ├── ChatList/              # Session list (@Observable view model)
│   ├── Home/                  # Home screen with entry cards
│   ├── NativeChat/            # Custom native chat (ViewModel, View, BubbleView,
│   │                          # SessionPickerView, SessionTabBar, ChatInputView)
│   └── Settings/              # Profile management + debug logs
├── Cards/                     # Music / Video / Image / Button / Markdown / Thinking
├── Design/                    # Theme, Typography
└── Resources/                 # Assets.xcassets
```

## Node Capabilities

When the gateway calls `node.invoke(deviceId, command)`, the
request is dispatched by `NodeCommandRouter`:

| Command | Status |
|---------|--------|
| `location.get` | Real — CoreLocation with `NSLocation*UsageDescription` prompts |
| `device.status` | Real — battery, thermal, storage, network |
| `device.info` | Real — device name, model, OS, app version |
| `canvas.*` | Stub — returns `ok: true` |
| `camera.list` / `camera.snap` / `camera.clip` | Stub |
| `photos.latest` | Stub |
| `contacts.search` / `contacts.add` | Stub |
| `calendar.events` / `calendar.add` | Stub |
| `reminders.list` / `reminders.add` | Stub |
| `talk.ptt.start` / `.stop` / `.cancel` / `.once` | Stub |
| `screen.record` / `system.notify` / `chat.push` | Stub |

Stubs are wired through the dispatch and registered with the
gateway at connect time, so they negotiate correctly. Promoting
any stub to a real handler is a localized change inside
`Core/NodeHandlers/`.

## Privacy Usage Descriptions

`Info.plist` is generated from `project.yml` by `xcodegen`. Edit
`project.yml` and re-run `xcodegen generate` to add a new key —
editing `Info.plist` directly is overwritten on the next regen.

Currently declared:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

When promoting a stub to a real implementation that touches a
privacy-protected API (camera, photos, contacts, calendar,
microphone, etc.), add the matching `NS*UsageDescription` to
`project.yml` `info.properties` before testing the new handler —
without the key, iOS silently ignores the permission request and
no prompt appears.

## Versioning

`config/Version.xcconfig` is the source of truth for the
human-facing version (`SMARTCHATAPP_MARKETING_VERSION = 0.0.1`).
The Apple-mandated `CFBundleVersion` is filled in at build time
by `scripts/inject-build-timestamp.sh`:

- **Local:** `git rev-list --count HEAD` (monotonic commit count)
- **CI:** `$BUILD_NUMBER` env (= `${{ github.run_number }}`)
- **Default:** `0` (safe for compile-only runs without git)

The script also writes a short git SHA into the non-standard
Info.plist key `SMARTCHATAPPGitSHA`. **Settings → About** shows
this in Debug builds (`Build 348.abc1234`) for at-a-glance "which
commit am I on" feedback; Release builds show the integer only
(per App Store Connect rules).

To bump the marketing version: edit `config/Version.xcconfig`
(and mirror it in `project.yml` `settings.base.MARKETING_VERSION`
as a fallback), then `make build`.

## Build scripts

Build-time helpers under `scripts/`. `Makefile` chains them as
prerequisites of `build`, `install`, and `compile-only`; you don't
need to invoke them directly.

| Script | Purpose |
|---|---|
| `scripts/inject-build-timestamp.sh` | Writes `BUILD_NUMBER` (monotonic int) and the short git SHA to `config/.local-version.xcconfig` so Xcode picks them up via the `#include?` chain. Idempotent (skips the write when nothing changed). |
| `scripts/ios-team-id.sh` | Prints the best Apple Developer Team ID from the local Mac's Xcode account list. Honors `IOS_DEVELOPMENT_TEAM` / `IOS_PREFERRED_TEAM_ID` env overrides. |
| `scripts/ios-configure-signing.sh` | Resolves a Team ID (via `ios-team-id.sh`) and writes it (plus canonical Bundle IDs) into `config/.local-signing.xcconfig`. Idempotent. Run by `make configure-signing`. |

## Build configuration

Three-layer xcconfig under `config/`, with `xcodegen` and Xcode
resolving the chain via `#include?`. Files marked `.example` are
templates you copy to the bare name and customize locally — they
are git-ignored once renamed.

| File | Role |
|---|---|
| `config/Signing.xcconfig` | Shared iOS signing defaults. `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE` resolve through `$(SMARTCHATAPP_*)` placeholders that the auto-detect script fills in. |
| `config/Version.xcconfig` | Shared version defaults. `SMARTCHATAPP_MARKETING_VERSION` and `SMARTCHATAPP_BUILD_NUMBER` are the source of truth; the xcconfig maps them to `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (the keys Xcode reads). |
| `config/Tests.xcconfig` | Bundle ID + signing for the unit-test target. |
| `config/.local-signing.xcconfig` | Auto-generated by `ios-configure-signing.sh` on every `make build`. **Git-ignored** — never commit. |
| `config/.local-version.xcconfig` | Auto-generated by `inject-build-timestamp.sh`. **Git-ignored** — never commit. |
| `config/LocalSigning.xcconfig.example` | Template for manual Team-ID overrides. Copy to `config/LocalSigning.xcconfig` and uncomment the lines you need. |
| `config/LocalVersion.xcconfig.example` | Template for manual version overrides (e.g. CI overrides). |

## Roadmap

Real implementations for the stubbed node capabilities — the
Node command bridge dispatches 8 stub commands (camera, photos,
contacts, calendar, reminders, talk, canvas, screen) that
return `ok: true` without doing anything. Promoting a stub to a
real implementation is a localized change in
`Core/NodeHandlers/` plus the matching `NS*UsageDescription`
in `project.yml`.

Open items, in priority order:

- `talk.ptt.*` real implementation (microphone push-to-talk)
- `camera.snap` real implementation (one-shot camera capture)
- `photos.latest` real implementation (latest photo query)
- Multi-gateway concurrent connections (currently the
  ProfileManager switches one gateway at a time)
- TestFlight / App Store distribution lane (currently
  sideload-only via GitHub Releases)

For "done since the last release" see
[CHANGELOG.md](CHANGELOG.md) — the roadmap here lists only
what's NOT done.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide (local
setup, picking an issue, code conventions, testing, security
disclosure). Short version: branch from `main`, match the
existing code style, run the test suite locally, update
[CHANGELOG.md](CHANGELOG.md), open a PR using the
[PR template](.github/PULL_REQUEST_TEMPLATE.md).

## License

MIT — see [LICENSE](LICENSE).
