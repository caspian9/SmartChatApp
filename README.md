# SmartChatApp

iOS chat client for [OpenClaw Gateway](https://github.com/openclaw/openclaw), with a native chat surface that streams the full agent event lifecycle (thinking, tool calls, command output, results) into the conversation.

> **Status:** early development. The app currently pairs the [OpenClawChatUI](https://github.com/openclaw/openclaw) SDK with a custom native chat surface for richer per-message rendering and a Node-command bridge that exposes on-device capabilities to the gateway.

## Features

- **Native chat UI** — Per-message bubbles for assistant, thinking, tool call, and tool result, with real-time streaming updates.
- **Streaming markdown** — Incremental updates via [MarkdownDisplayView](https://github.com/zjc19891106/MarkdownDisplayView).
- **Interactive cards** — Music, video, image, button, markdown, and thinking content.
- **Multi-gateway profiles** — Switch between any number of OpenClaw Gateway instances, with TLS and token auth per profile.
- **Session picker** — Drill down Gateway → Agent → Channel → Session in a single header strip.
- **Per-session message cache** — Local persistence with collapse-state cache for long-history handling.
- **Node capabilities** — `location.get`, `device.status`, `device.info` fully implemented; canvas, camera, photos, contacts, calendar, reminders, talk, screen, and system commands wired as stubs ready for real implementations.

## Requirements

- macOS with **Xcode 16.4** (project local) / **Xcode 26.3** (CI to match the OpenClawKit sibling's swift-tools-version 6.2)
- iOS **18.0** deployment target
- A connected iPhone for device builds (Xcode 15+ uses the CoreDevice framework, not the legacy `lockdownd`). `make compile-only` works without one.
- An [OpenClaw Gateway](https://github.com/openclaw/openclaw) instance to connect to

## Build

```bash
# Generate the Xcode project (XcodeGen reads project.yml)
xcodegen generate

# Build and install on the first connected iPhone
make install

# Build only
make build

# List connected devices
make list-devices
```

The `Makefile` auto-detects the first connected iPhone via `xcrun devicectl list devices`.

## Sourcing OpenClawKit

`project.yml` declares `OpenClawKit` as a path-linked Swift package (see `packages.OpenClawKit.path` in `project.yml`). This means the local working tree must have OpenClawKit at `../openclaw/apps/shared/OpenClawKit/` relative to the `SmartChatApp/` checkout — they must be siblings:

```
workspace/
├── SmartChatApp/   ← this repo
└── openclaw/       ← OpenClawKit fork
    └── apps/shared/OpenClawKit/
```

The CI workflow (`.github/workflows/ci.yml`) clones the fork automatically into `../openclaw` before invoking `xcodegen`, so you don't need to do anything on CI. Locally, clone (or symlink) the fork into the sibling position before running `make build`.

## Versioning

`config/Version.xcconfig` is the source of truth for the human-facing version (`SMARTCHATAPP_MARKETING_VERSION = 0.0.1`). The Apple-mandated `CFBundleVersion` is filled in at build time by `scripts/inject-build-timestamp.sh`:

- **Local:** `git rev-list --count HEAD` (monotonic commit count)
- **CI:** `$BUILD_NUMBER` env (= `${{ github.run_number }}`)
- **Default:** `0` (safe for compile-only runs without git)

The script also writes a short git SHA into the non-standard Info.plist key `SMARTCHATAPPGitSHA`. **Settings → About** shows this in Debug builds (`Build 348.abc1234`) for at-a-glance "which commit am I on" feedback; Release builds show the integer only (per App Store Connect rules).

To bump the marketing version: edit `config/Version.xcconfig` (and mirror it in `project.yml` `settings.base.MARKETING_VERSION` as a fallback), then `make build`.

## Tech Stack

- **SwiftUI** for the UI
- **iOS 17 Observation** (`@Observable` + `@MainActor`) for state management
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** for the project file (also the source of truth for `Info.plist`)
- **[OpenClawKit](https://github.com/openclaw/openclaw)** (path-linked from `../openclaw`) for the gateway protocol and chat UI
- **[MarkdownDisplayView](https://github.com/zjc19891106/MarkdownDisplayView)** for streaming markdown rendering

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

When the gateway calls `node.invoke(deviceId, command)`, the request is dispatched by `NodeCommandRouter`:

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

Stubs are wired through the dispatch and registered with the gateway at connect time, so they negotiate correctly. Promoting any stub to a real handler is a localized change inside `Core/NodeHandlers/`.

## Privacy Usage Descriptions

`Info.plist` is generated from `project.yml` by `xcodegen`. Edit `project.yml` and re-run `xcodegen generate` to add a new key — editing `Info.plist` directly is overwritten on the next regen.

Currently declared:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

When promoting a stub to a real implementation that touches a privacy-protected API (camera, photos, contacts, calendar, microphone, etc.), add the matching `NS*UsageDescription` to `project.yml` `info.properties` before testing the new handler — without the key, iOS silently ignores the permission request and no prompt appears.

## Roadmap

- [ ] Real implementations for the stubbed node capabilities (camera, photos, contacts, calendar, reminders, talk, canvas, screen)
- [x] GitHub Actions CI (`.github/workflows/ci.yml`) — real `xcodebuild build` + `xcodebuild test` on `macos-15`
- [x] Issue and PR templates (`.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md`)
- [x] Test coverage for `NativeChatViewModel` and event-stream handling (9 test files: scroll request, formatter, connection coordinator coalescing, state machine, transport, logger, session key, chat message converter, app logger)

## Contributing

Issues and PRs are welcome. Please follow the existing commit style: `feat:`, `fix:`, `docs:`, `refactor:`, and `Revert "<original>"` for revert commits.

## License

MIT — see [LICENSE](LICENSE).
