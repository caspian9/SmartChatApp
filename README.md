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

- macOS with **Xcode 15+**
- iOS **18.0+** deployment target
- A connected iPhone for device builds (Xcode 15+ uses the CoreDevice framework, not the legacy `lockdownd`)
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

## Tech Stack

- **SwiftUI** for the UI
- **[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) 1.9.3** for state management
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
│   ├── ChatList/              # TCA-driven session list
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
- [ ] GitHub Actions CI (`.github/workflows/ci.yml`) for PR build verification on `macos-14` / `macos-15` runners
- [ ] Issue and PR templates
- [ ] Test coverage for `NativeChatViewModel` agent event stream handling

## Contributing

Issues and PRs are welcome. Please follow the existing commit style: `feat:`, `fix:`, `docs:`, `refactor:`, and `Revert "<original>"` for revert commits.

## License

MIT — see [LICENSE](LICENSE).
