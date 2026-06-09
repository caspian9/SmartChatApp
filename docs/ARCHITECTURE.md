# Architecture

Detailed architecture notes. `../CLAUDE.md` points here for depth;
this file is optional reading for new contributors.

## Layered architecture

```
Presentation Layer (SwiftUI Views)
    ↓
Feature Layer (@MainActor @Observable ViewModels)
    ↓
Service Layer (OpenClawClient, CardRegistry)
    ↓
Network Layer (URLSession + SSE Streaming)
```

## State management pattern

State lives in `@MainActor @Observable` classes (iOS 17+ Observation).
Each feature is a single class file plus a SwiftUI view:

- `FeatureNameViewModel.swift` — `@MainActor @Observable final class`
  with stored properties for state and methods for actions
- `FeatureNameView.swift` — SwiftUI view holding
  `@State private var viewModel = FeatureNameViewModel()` and calling
  `viewModel.someMethod(...)` directly

This matches the OpenClawKit SDK's own `OpenClawChatViewModel`
pattern. `@MainActor` makes all state mutations main-thread-safe;
the `@Observable` macro drives SwiftUI re-renders on property
changes. Long-running work is dispatched via `Task { ... }` and hops
back to main actor when calling other methods.

## Node command handlers

Node commands are handled by `NodeCommandRouter` via the `onInvoke`
callback during node connection:

| Command | Handler | Status |
|---------|---------|--------|
| `location.get` | LocationService | Full implementation (requires `NSLocation*UsageDescription` in `Info.plist`) |
| `device.status` | DeviceService | Full implementation (battery, thermal, storage, network) |
| `device.info` | DeviceService | Full implementation (device name, model, OS, app version) |
| `canvas.*` | stub | Returns ok: true |
| `screen.record` | stub | Returns ok: true |
| `talk.ptt.*` | stub | Returns ok: true |
| `camera.*` | stub | Returns ok: true |
| `photos.latest` | stub | Returns ok: true |
| `contacts.*` | stub | Returns ok: true |
| `calendar.*` | stub | Returns ok: true |
| `reminders.*` | stub | Returns ok: true |

When promoting a stub to a real implementation, add the matching
`NS*UsageDescription` to `project.yml` `info.properties` and re-run
`xcodegen generate` before testing the new handler. The privacy key
table in `../CLAUDE.md` is the source of truth for what the app
actually invokes.

## OpenClaw Gateway protocol

### Connection flow

1. Connect via WebSocket to Gateway URL
2. Send `ConnectParams` with protocol version and auth
3. Receive `hello-ok` with negotiated features
4. Use `sessions.create/send/subscribe` for messaging

### Key API methods

- `sessions.create` — Create new session
- `sessions.send` — Send message (HTTP POST)
- `sessions.subscribe` — Subscribe to message stream (SSE)
- `sessions.patch` — Modify session parameters

### Agent event streams

The server emits agent activity on `payload.stream` values, switched
in `NativeChatViewModel.handleTransportEvent`. **Verbose is off by
default** — modern servers send `item` + `command_output` for
tool/command activity, and `tool` is only emitted when verbose is on.

| Stream | Phase / Kind | Surfaced as | Notes |
|--------|--------------|-------------|-------|
| `lifecycle` | `start` / `end` | Drives the assistant placeholder + run finalization | One per run |
| `assistant` | `delta` | Updates the assistant bubble (cumulative text → `MarkdownStreamManager`) | |
| `thinking` | `delta` | Thinking bubble, one per run (id `runId:thinking`) | |
| `item` | kind = tool / command / patch / search / analysis; phase = start / update / end | `toolCall` bubble (id `runId:item:<itemId>`) | **Default path — verbose=off.** On phase=end with a summary or error, also creates a `toolResult` bubble. |
| `command_output` | `delta` / `end` | `toolResult` bubble (id `runId:itemResult:<itemId>`) | On end, appends `exit=X duration=Yms` |
| `tool` | legacy | `toolCall` bubble (id `runId:tool:<toolCallId>`) | Only emitted when verbose is on; prefer the `item` path |
| `plan` / `approval` / `patch` / `compaction` / `error` | — | Logged but not surfaced | |
