# Gateway Connection Management Refactor — Design

## Context

`SmartChatApp/SmartChatApp/Core/Network/SessionManager.swift` is an `actor` singleton (the right shape), but its **consumers** duplicate work in ways the openclaw gateway server's protocol never intended:

- 7+ call sites of `ensureConnected()` race independently; only `operatorConnected` is a fast-path
- `makeTransport(sessionKey:)` returns a **new** `GatewayChatTransport` actor per call, opening a fresh `AsyncStream` subscription to the same underlying `GatewayNodeSession` each time
- A single mutable `currentSessionKey` slot is overwritten on every `makeTransport`; concurrent `loadSessions` / `loadHistory` / `sendMessage` race on it (documented in `HistoryLoader.swift:81-86`)
- Three views (`HomeView`, `ProfileListView`, `EditProfileSheet`) each hold their own `isConnected` `@State`, with `HomeView` polling every 2s via a `Timer` instead of being event-driven
- Old-UI `ChatListView` and new-UI `NativeChat` each open their own `GatewayChatTransport` for the same `operatorSession`, so a `sendMessage` in NativeChat will not deliver events to a parallel `ChatList` `OpenClawChatView`
- `SessionManager.connect` opens the WebSocket with a raw `URLSession.shared` call, bypassing `GatewayNodeSession`'s built-in handshake nonce signing, exponential reconnect, tick watchdog, and auth-pause logic

The openclaw server (`/Users/hai/Code/openclaw/src/gateway/server/ws-connection.ts`) is **explicitly designed to multiplex many sessions on a single connection** via `sessions.subscribe`. The official iOS app (`/Users/hai/Code/openclaw/apps/ios/`) demonstrates the canonical pattern: one process-level `NodeAppModel` holding two `GatewayNodeSession` instances (`operatorGateway` + `nodeGateway`), lifecycle driven by their `onConnected` / `onDisconnected` / `onReconnectPaused` callbacks, and a separate `GatewayConnectionController` for discovery and policy.

**Goal:** Make the app's connection management match the server's intended pattern (one shared transport, multiplexed by session key), with a single observable connection state for the UI, an in-flight `ensureConnected` de-duplicator, and a transport-adapter boundary so the SDK is replaceable from one file.

**Non-Goals:**
- No changes to view API (settings, chat, native chat UIs keep reading what they read)
- No protocol changes
- No new features (no new reconnect strategies, no auth refresh UI — only if encountered)
- No SDK upgrade or feature adoption
- No migration of old-UI `ChatListView` / `ChatView` to the new pattern (separate scope)

## Current State (Audit Findings)

### Connection entry points (all in `/Users/hai/Code/SmartChatApp/`)

| File:Line | Call | Frequency |
|---|---|---|
| `App/SmartChatAppApp.swift:27` | `ensureConnected()` | Launch only |
| `Core/Services/ProfileManager.swift:105,107,111` | `connectionStatus`, `disconnect`, `connectWithProfile` | On profile switch |
| `Features/ChatList/ChatListView.swift:77,78,96,103,112,113,114` | `ensureConnected` + `makeTransport` per refresh/session/create | Every action |
| `Features/Home/HomeView.swift:121,122` | `connectionStatus`, `deviceName` (read in 2s `Timer`) | Polled |
| `Features/Settings/ProfileListView.swift:54,87,92,93,106,107` | connect/disconnect + `connectionStatus` | On user action |
| `Features/Settings/EditProfileSheet.swift:115,119,139,282` | gatewayURL, `connectWithRole`, `disconnect`, `connectionStatus` | On user action |
| `Features/NativeChat/Internal/SessionCoordinator.swift:49,51,59,60,216,218,259,260` | `ensureConnected` + `makeTransport("")` × 4 | On every load/switch/create |
| `Features/NativeChat/Internal/HistoryLoader.swift:73,74` | `ensureConnected` + `makeTransport` | Per history load |
| `Features/NativeChat/NativeChatViewModel.swift:115,116,123` | `ensureConnected`, `makeTransport`, `getCurrentSessionKey` | Per send |

### Duplicated state (3 views, no shared source)

- `Features/Home/HomeView.swift:9-10` — `@State isConnected`, `isConnecting` (polled every 2s)
- `Features/Settings/ProfileListView.swift:8-10` — local `isConnected`, `connectingProfileId`, `failedProfileId`
- `Features/Settings/EditProfileSheet.swift:23-24` — local `isConnected`, `isTesting`
- `Features/ChatList/ChatListView.swift:8` — local `isLoading`
- `Features/NativeChat/NativeChatViewModel.swift:22-24` — `isLoading`, `isSending`, `isSwitchingGateway` (set by `SessionCoordinator`)

### Dead code

- `Core/Network/GatewayClient.swift` — 0 callers
- `SessionManager.reconnect()` (line 434) — 0 callers

### SDK primitives not used

`/Users/hai/Code/openclaw/apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayNodeSession.swift` already provides:
- `connect(...)` (line 187) — handshake nonce wait + device signing
- `subscribeServerEvents(bufferingNewest:)` (line 339) — multi-consumer fan-out
- `onConnected` / `onDisconnected` / `onReconnectPaused` callbacks
- Exponential reconnect 500ms→30s (line 228, 386, 925-926)
- 30s watchdog (line 320-340)
- 15s ping keepalive (line 242, 405-420)
- Tick-miss auto-reconnect (line 907-915)
- Auth-failure pause (line 248, 325, 924-936)

App code bypasses all of these by opening the WebSocket directly with `URLSession.shared`.

## Target Architecture (Plan B)

### Layered model

```
┌────────────────────────────────────────────────────────────────┐
│ Views (Home / ProfileList / EditProfileSheet / NativeChat /   │
│        ChatList / Chat) — observe ConnectionState             │
└──────────────────────────┬─────────────────────────────────────┘
                           │ @Observable reads
┌──────────────────────────▼─────────────────────────────────────┐
│ ConnectionState (@MainActor @Observable, app-singleton)        │
│ - phase: .disconnected | .connecting | .connected |            │
│         .reconnecting | .reconnectPaused(AuthFailure)          │
│ - connectedDeviceName: String?                                 │
│ - lastError: String?                                           │
│   Source of truth; written by ConnectionCoordinator            │
└──────────────────────────┬─────────────────────────────────────┘
                           │ updates
┌──────────────────────────▼─────────────────────────────────────┐
│ ConnectionCoordinator (@MainActor)                             │
│ - owns 2 GatewayNodeSession (operator + node) — borrowed       │
│ - wires session.onConnected / onDisconnected /                 │
│   onReconnectPaused → ConnectionState                         │
│ - coalesces ensureConnected() via in-flight Task leader        │
│ - provides getTransport(sessionKey:) returning the SAME        │
│   GatewayChatTransport for the same (role, sessionKey)         │
│ - persists device token by (deviceId, role) to Keychain        │
└──────────────────────────┬─────────────────────────────────────┘
                           │ uses
┌──────────────────────────▼─────────────────────────────────────┐
│ TransportAdapter (protocol — SDK-agnostic)                     │
│ - request(method:params:timeout:) async throws -> Data        │
│ - events() -> AsyncStream<EventFrame>                          │
│ - sendMessage / listSessions / requestHistory                  │
│   (typed convenience over request + JSON)                      │
└──────────────────────────┬─────────────────────────────────────┘
                           │ today
┌──────────────────────────▼─────────────────────────────────────┐
│ SDKGatewayTransportAdapter (concrete — wraps                   │
│ GatewayNodeSession)                                            │
│ - the ONLY file that imports openclaw's EventFrame,            │
│   node.invoke.*, etc.                                          │
│ - drop-in replaceable: HTTPGatewayTransportAdapter,            │
│   MockTransportAdapter (tests), etc.                           │
└────────────────────────────────────────────────────────────────┘
```

### File layout

```
SmartChatApp/
├── Core/
│   ├── Network/
│   │   ├── SessionManager.swift            (REFACTOR — thin wrapper over ConnectionCoordinator; keeps public API for ProfileManager / ProfileListView)
│   │   ├── GatewayChatTransport.swift      (unchanged — the SDK transport, cached per sessionKey by ConnectionCoordinator)
│   │   ├── ConnectionState.swift           (NEW — @Observable phase + flags)
│   │   └── ConnectionCoordinator.swift     (NEW — owns sessions, wires callbacks, coalesces ensureConnected, caches GatewayChatTransport)
│   ├── Services/
│   │   └── ProfileManager.swift            (unchanged — calls SessionManager which forwards)
│   └── ...
├── Features/
│   ├── Home/HomeView.swift                 (replace 2s timer with @Observable ConnectionState read)
│   ├── Settings/ProfileListView.swift      (read ConnectionState; remove local isConnected)
│   ├── Settings/EditProfileSheet.swift     (read ConnectionState; remove local isConnected)
│   ├── ChatList/ChatListView.swift         (use cached transport via await SessionManager.shared.makeTransport)
│   └── NativeChat/                         (no API change — fix racy getCurrentSessionKey guard at line 123)
```

**Why no separate `TransportAdapter` protocol:**

The openclaw SDK already exposes `OpenClawChatTransport` (in `OpenClawChatUI/ChatTransport.swift:12`) — a clean, public, Sendable protocol that the app's transport-cache returns. `ConnectionCoordinator.getTransport(sessionKey:)` returns `any OpenClawChatTransport` (concrete impl = `GatewayChatTransport`). This is the SDK boundary today.

If we drop the SDK tomorrow, we change `ConnectionCoordinator.getTransport`'s return type to a new protocol and update the 4 call sites (`ChatListView.sessionView`, `ChatListView.refreshFromNetwork`, `ChatListView.createSession`, `NativeChatViewModel.sendMessage`). All other code is unchanged.

### ConnectionCoordinator responsibilities

1. **Owns** 2 `GatewayNodeSession` (operator + node) — borrowed from `SessionManager`'s existing fields. (We do **not** re-create them; we add a coordinator that holds weak references and wires their callbacks.)
2. **`ensureConnected(for role: .operator | .node) async throws`**: returns immediately if `phase == .connected`. Otherwise starts (or awaits the in-flight) connect `Task` for that role.
3. **Wires callbacks** on both sessions:
   - `onConnected` → `ConnectionState.phase = .connected`
   - `onDisconnected` → `ConnectionState.phase = .disconnected` (then trigger reconnect via SDK's built-in loop)
   - `onReconnectPaused` → `ConnectionState.phase = .reconnectPaused(.authFailure)`
4. **Provides `getTransport(for role:, sessionKey: String) -> GatewayChatTransport`**: caches one transport per `(role, sessionKey)`. Old `makeTransport(sessionKey:)` callers become `getTransport(role: .operator, sessionKey: ...)` (default role is `.operator` for chat).
5. **Persists device token** in Keychain by `(deviceId, role)`, hands to `GatewayNodeSession.connect(...)` on next launch.

### ConnectionState responsibilities

```swift
@MainActor
@Observable
final class ConnectionState {
    enum Phase: Equatable {
        case disconnected
        case connecting(role: GatewayRole)
        case connected
        case reconnecting(reason: String)
        case reconnectPaused(AuthFailure)
    }
    enum AuthFailure: Equatable {
        case tokenMismatch
        case scopeInsufficient
        case versionUnsupported
    }
    enum GatewayRole: String, CaseIterable { case operator, node }

    private(set) var phase: Phase = .disconnected
    private(set) var connectedDeviceName: String?
    private(set) var lastError: String?
    private(set) var reconnectAttempts: Int = 0
    // role -> connect-in-flight Task<Void, Error>  (coalescing)
    let coordinator: ConnectionCoordinator
    static let shared = ConnectionState(coordinator: .shared)
}
```

Views read these directly (no timer). `onChange(of: connectionState.phase)` for transitions.

### SDK Reuse Decisions (locked)

| App concern | Decision |
|---|---|
| WebSocket connect | **Use `GatewayNodeSession.connect(...)`**, not raw `URLSession.shared` (fixes handshake race) |
| Reconnect/backoff | **Use SDK's built-in** exponential 500ms→30s; do not custom-implement |
| Heartbeat | **Use SDK's 15s ping** (line 242); do not custom-implement |
| Tick watchdog | **Use SDK's tick-miss detector** (line 907-915); do not custom-implement |
| Auth pause | **Use SDK's `onReconnectPaused`**; surface in `ConnectionState.phase` |
| Event fan-out | **Use `subscribeServerEvents(bufferingNewest:)`** (line 339); one subscription per coordinator, multiple consumers via `AsyncStream` multiplexing |
| Chat transport (events → `OpenClawChatTransportEvent`) | **Wrap SDK's `GatewayNodeSession` in `SDKGatewayTransportAdapter`**; expose `OpenClawChatTransport` interface to the rest of the app |
| Device token | **Persist in Keychain**; not in UserDefaults (sensitive) |
| `GatewayClient.swift` | **Delete** (dead code) |
| `SessionManager.reconnect()` | **Delete** (dead code) |
| `SessionManager.currentSessionKey` | **Delete** (race-condition slot; consumers read `selectedSession?.key` instead) |
| `SessionManager.makeTransport` | **Refactor → `ConnectionCoordinator.getTransport(role:sessionKey:)`** (returns cached instance) |
| `SessionManager.ensureConnected` | **Refactor → `ConnectionCoordinator.ensureConnected(for:)`** (coalesced; in-flight Task leader) |
| `SessionManager` public API | **Keep** (ProfileManager, ProfileListView, EditProfileSheet all call it) — but delegate to ConnectionCoordinator |

## Q&A — Resolved Design Questions

### Q1: SDK direction or openclaw source direction?

Both, unified. The official iOS app (`openclaw/apps/ios/`) is the SDK-consumption exemplar: it uses `GatewayNodeSession` (SDK primitive) inside `NodeAppModel` (app-level coordinator). The "two directions" are not in conflict; they are the same recipe at different layers. Our `ConnectionCoordinator` plays `NodeAppModel`'s role, our `ConnectionState` is its observable projection, and our `TransportAdapter` is the boundary that lets us swap SDKs.

### Q2: Reference the SDK, or implement our own?

Reference the SDK. Reimplementing the openclaw protocol (handshake nonce, device signing, tick watchdog, sequence-gap reconciliation, auth-pause) from `client.ts` is high-risk and high-maintenance, with no upside. The SDK already provides a test seam (`WebSocketSessionBox`) and a port validated by the openclaw team. Our boundary is the `TransportAdapter` protocol, not "should we use the SDK."

### Q3: Is the SDK the best? Problems? Escape plan if dropped?

The SDK is good for what it is: a faithful port of the openclaw protocol in Swift. Problems:

1. **Protocol coupling**: `GatewayNodeSession` is hard-coded to openclaw's event/req schema. Any server protocol change = SDK release = app upgrade (or pin & lag).
2. **No streaming abstraction**: `OpenClawChatTransport.sendMessage` is RPC; LLM token-by-token is reconstructed from a `chat` event fan-out. Swapping in OpenAI/Anthropic streaming = different transport interface.
3. **`OpenClawChatUI` value types mirror protocol fields** (`OpenClawChatMessageContent.thinking`, `.toolCallId`). Server schema rename = type rename = consumer rename.
4. **No "how many sessions per app" guidance** — the SDK pushes that policy to the consumer (`NodeAppModel` chooses operator+node; nothing stops an app from running 5).
5. **Actor-isolated event streams** are awkward for shared consumers with backpressure.
6. **Versioned with the server**: protocol changes ship as SDK releases; pinning the SDK means lagging the server; not pinning means breakage on every server deploy.

**Escape plan if we drop the SDK:**

- The boundary is the SDK's `OpenClawChatTransport` protocol (`OpenClawChatUI/ChatTransport.swift:12`). `ConnectionCoordinator.getTransport(sessionKey:)` returns `any OpenClawChatTransport` (concrete impl = `GatewayChatTransport`).
- To swap, change `ConnectionCoordinator.getTransport`'s return type (or keep `OpenClawChatTransport` and make the new transport conform to it) and replace `GatewayChatTransport` with the new transport's concrete impl.
- 4 call sites use the returned transport: `ChatListView.sessionView` (line 96), `ChatListView.refreshFromNetwork` (line 78), `ChatListView.createSession` (line 114), `NativeChatViewModel.sendMessage` (line 116). All already use it through the protocol surface — type-only changes.
- `OpenClawChatUI` value types (`ChatMessage`, `OpenClawChatMessage`, `OpenClawChatTransportEvent`, `OpenClawChatMessageContent`) are consumed but not coupled to the transport. Replace with own types as a separate refactor.
- `ConnectionState`, `ConnectionCoordinator`, `SessionManager` (refactored) all stay; no internal change beyond the return type.
- No UI code changes.

**Net: the SDK is a sound choice; the fix is a boundary, not a replacement.**

## Migration Order (sketch — full plan in `plans/` doc)

The implementation plan (next deliverable, via writing-plans skill) will follow this order so each step compiles & tests pass before the next:

**Phase A — Foundation (no consumer changes)**
1. Add `ConnectionState.swift` (`@Observable` enum-based phase)
2. Add `TransportAdapter.swift` (protocol + `SDKGatewayTransportAdapter` implementation that wraps today's `GatewayChatTransport`)
3. Add `ConnectionCoordinator.swift` (owns sessions, wires callbacks, coalesces `ensureConnected`, caches transports, persists device token)
4. Add `KeychainStore` helper (or reuse existing) for device-token persistence
5. Delete dead code: `GatewayClient.swift`, `SessionManager.reconnect()`, `SessionManager.currentSessionKey`

**Phase B — Migrate SessionManager**
6. Refactor `SessionManager` to delegate to `ConnectionCoordinator` (keep its public API; internals are one-line forwards)
7. `ProfileManager.switchToProfile` and `ProfileListView.connect/disconnect` keep working unchanged

**Phase C — Migrate UI**
8. `HomeView`: replace 2s `Timer` with `@Observable ConnectionState` read
9. `ProfileListView`: read `ConnectionState.phase` instead of local `isConnected`
10. `EditProfileSheet`: read `ConnectionState.phase` instead of local `isConnected`
11. `ChatListView`: use `ConnectionCoordinator.getTransport(role: .operator, sessionKey: ...)` instead of fresh `GatewayChatTransport` per `ChatView`

**Phase D — Verify**
12. `make build`, run app, manual smoke test
13. Run 55 unit tests

## Critical Files

| Path | Action |
|---|---|
| `SmartChatApp/Core/Network/ConnectionState.swift` | NEW |
| `SmartChatApp/Core/Network/ConnectionCoordinator.swift` | NEW |
| `SmartChatApp/Core/Network/TransportAdapter.swift` | NEW (protocol + SDK impl) |
| `SmartChatApp/Core/Network/SessionManager.swift` | REFACTOR (thin wrapper) |
| `SmartChatApp/Core/Network/GatewayChatTransport.swift` | unchanged (consumed by SDKGatewayTransportAdapter) |
| `SmartChatApp/Core/Network/GatewayClient.swift` | DELETE (dead) |
| `SmartChatApp/Core/Services/ProfileManager.swift` | minor — delegate to ConnectionCoordinator |
| `SmartChatApp/Features/Home/HomeView.swift` | replace 2s timer with @Observable read |
| `SmartChatApp/Features/Settings/ProfileListView.swift` | read ConnectionState |
| `SmartChatApp/Features/Settings/EditProfileSheet.swift` | read ConnectionState |
| `SmartChatApp/Features/ChatList/ChatListView.swift` | use cached transport |
| `SmartChatAppTests/` | no new tests initially; smoke is via simulator |

## Reused Existing Code

- **`GatewayNodeSession` + `subscribeServerEvents`** (`openclaw/apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayNodeSession.swift`) — all reconnect/heartbeat/tick/auth-pause logic is reused as-is
- **`OpenClawChatTransport` protocol** (`openclaw/apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatTransport.swift:12`) — the boundary we depend on
- **`@Observable` macro** — for `ConnectionState` (same pattern as `NativeChatViewModel`)
- **`OSAllocatedUnfairLock`** — for `ensureConnected` in-flight task coalescing
- **`MessageCache` / `SessionCache`** — unchanged; already transport-agnostic

## Verification

### Automated

1. **Build:** `make build` — no new warnings
2. **Tests:** `xcodebuild test -scheme SmartChatApp` — 55/55 still pass (no test changes expected)

### Manual Smoke (iPhone simulator)

1. Launch app → confirm `ConnectionState.phase` transitions to `.connected` (Home header green dot appears immediately, no 2s lag)
2. Switch gateway profile → confirm `.disconnected → .connecting → .connected` transition visible in real-time
3. Open `ProfileListView` → confirm `isConnected` reflects `ConnectionState.phase`, no independent polling
4. Open `NativeChat` → send a message → confirm:
   - Single `GatewayChatTransport` instance reused across the session (verified in debugger: `coordinator.getTransport(role: .operator, sessionKey:)` returns same actor identity)
   - `currentSessionKey` slot is gone (grep returns 0 hits)
5. Open old-UI `ChatListView` in parallel with `NativeChat` → send in NativeChat → confirm `ChatList` also receives `chat` events (proves event fan-out works)
6. Disconnect wifi → confirm `.reconnecting` appears, SDK backoff kicks in (1s, 2s, 4s, ..., 30s cap)
7. Restore wifi → confirm `.connected` without manual intervention
8. Force token mismatch (test fixture) → confirm `.reconnectPaused(.tokenMismatch)` appears, app shows re-auth UI

### What MUST NOT Change

- Public API of `NativeChatViewModel` (4 collaborators, public methods, observable properties)
- `SessionManager` public surface (so `ProfileManager` and views keep working) — internals only
- View layouts / colors / strings
- Any test that depends on `SessionManager` API (none expected to change)

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `GatewayNodeSession` callbacks fire on actor isolation, not MainActor | Wrap writes to `ConnectionState` in `MainActor.run { }` or mark callback bridge `@MainActor` |
| `ensureConnected` in-flight task leaks if all callers cancel | Use a `Task` with weak self; if cancelled, leader cleans up on completion |
| Cached `GatewayChatTransport` outlives its session (e.g., session deleted) | Add `invalidateTransport(sessionKey:)` method; called by `SessionCoordinator.deleteSession` |
| Device token persistence in Keychain needs entitlement | Check app's existing Keychain access; if not present, add `keychain-access-groups` to entitlements (or fall back to encrypted file in app group) |
| `subscribeServerEvents` is a multi-consumer AsyncStream — ordering between old-UI ChatList and new-UI NativeChat is per-session, not cross-session | Document this; tests should not assert cross-session order |
| Switching to SDK's reconnect means losing app's custom "stop reconnecting on background" logic | Use `setScenePhase(.background)` → `GatewayNodeSession.disconnect()`; SDK's reconnect won't fight a deliberate disconnect (verify with the SDK's `shouldReconnect` option) |
| `ConnectionState.shared` (singleton) is a hidden global | Acceptable for app-level state; mirror `SessionManager.shared` precedent; tests can construct their own |
| Profile-switch race: profile A's session.disconnect() happens concurrently with profile B's session.connect() | `ConnectionCoordinator.switchProfile` is serialized; cancels A's in-flight `ensureConnected` before starting B's |
| Test coverage drops if we add a coordinator (new code, no tests) | Add unit tests for `ConnectionCoordinator.coalesce(ensureConnected:)` and `ConnectionState` phase transitions; smoke covers the rest |
