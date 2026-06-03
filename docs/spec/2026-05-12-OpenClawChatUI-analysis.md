# OpenClawChatUI Module Analysis

**Updated:** 2026-05-12

> **Status: Historical (2026-05-12).** Snapshot analysis of the
> `OpenClawChatUI` SDK at the time it was integrated. For the
> authoritative description of how SmartChatApp uses this SDK today,
> see [`../../CLAUDE.md`](../../CLAUDE.md) (Key Components table) and
> [`../../README.md`](../../README.md). This file is preserved as a
> record of the original analysis and is not edited as the code
> evolves.

## Overview

`OpenClawChatUI` is a SwiftUI-based chat UI module in OpenClawKit that provides a complete chat interface with streaming support, session management, and message rendering.

## Architecture

```
OpenClawChatView (public struct, SwiftUI View)
    ├── OpenClawChatComposer (internal struct, View)
    │   └── OpenClawChatViewModel (final class, @Observable)
    │       └── OpenClawChatTransport (public protocol)
    ├── ChatMessageBubble (internal struct, View)
    ├── ChatStreamingAssistantBubble (internal struct, View)
    ├── ChatPendingToolsBubble (internal struct, View)
    ├── ChatSessionsSheet (internal struct, View)
    └── ChatTypingIndicatorBubble (internal struct, View)

OpenClawChatEventText (public static helpers)
ChatMarkdownPreprocessor (internal, static-only)
ChatMarkdownRenderer (internal, View)
AssistantTextParser (internal, static-only)
ToolResultTextFormatter (internal, static-only)
ChatTheme (internal, static-only)
```

## File Inventory

### Public API Surface

| File | Type | Access | Purpose |
|------|------|--------|---------|
| `ChatView.swift` | `OpenClawChatView` | `public struct` | Main SwiftUI View component |
| `ChatViewModel.swift` | `OpenClawChatViewModel` | `public final class` | Observable state manager |
| `ChatTransport.swift` | `OpenClawChatTransport` | `public protocol` | Transport implementation protocol |
| `ChatTransport.swift` | `OpenClawChatTransportEvent` | `public enum` | Event types for async stream |
| `ChatEventText.swift` | `OpenClawChatEventText` | `public enum` | Static helpers for event text |
| `ChatModels.swift` | Various | `public struct` | Data models (messages, sessions, etc.) |

### Internal Components

| File | Type | Access | Purpose |
|------|------|--------|---------|
| `ChatComposer.swift` | `OpenClawChatComposer` | `internal struct` | Message input composer |
| `ChatMessageViews.swift` | `ChatMessageBubble` etc. | `internal struct` | Message display views |
| `ChatMarkdownRenderer.swift` | `ChatMarkdownRenderer` | `internal struct` | Markdown rendering |
| `ChatTheme.swift` | `OpenClawChatTheme` | `internal enum` | Theme colors and styles |
| `AssistantTextParser.swift` | `AssistantTextParser` | `internal enum` | Text parsing utilities |
| `ChatMarkdownPreprocessor.swift` | `ChatMarkdownPreprocessor` | `internal enum` | Markdown preprocessing |
| `ToolResultTextFormatter.swift` | `ToolResultTextFormatter` | `internal enum` | Tool result formatting |

## Key Types

### OpenClawChatViewModel

**Status:** `public final class` — **Cannot be subclassed**

```swift
@MainActor
@Observable
public final class OpenClawChatViewModel {
    // Public properties (most are private(set))
    public private(set) var messages: [OpenClawChatMessage]
    public var input: String
    public private(set) var streamingAssistantText: String?
    public private(set) var pendingToolCalls: [OpenClawChatPendingToolCall]
    public private(set) var sessions: [OpenClawChatSessionEntry]
    public private(set) var isLoading: Bool
    public private(set) var healthOK: Bool
    // ... more properties

    // Public methods
    public func load()
    public func refresh()
    public func send()
    public func abort()
    public func switchSession(to:)
    public func selectThinkingLevel(_:)
    public func selectModel(_:)
}
```

**Key internal methods (not overridable):**
- `handleAgentEvent(_:)` — `private` — handles agent events
- `bootstrap()` — `private` — initial load logic
- `fetchSessions(limit:)` — `private` — session fetching

### OpenClawChatTransport

**Status:** `public protocol` — **Main extension point**

```swift
public protocol OpenClawChatTransport: Sendable {
    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    func sendMessage(...) async throws -> OpenClawChatSendResponse
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse
    func events() -> AsyncStream<OpenClawChatTransportEvent>
    // ... more methods
}
```

### OpenClawChatTransportEvent

```swift
public enum OpenClawChatTransportEvent: Sendable {
    case health(ok: Bool)
    case tick
    case chat(OpenClawChatEventPayload)
    case sessionMessage(OpenClawSessionMessageEventPayload)
    case agent(OpenClawAgentEventPayload)
    case seqGap
}
```

## Extension Points

### Primary Extension Point: OpenClawChatTransport

You can implement `OpenClawChatTransport` to provide a custom backend:

```swift
public actor GatewayChatTransport: OpenClawChatTransport {
    // Implement all required methods
    // Provide WebSocket/SSE connection to backend
}
```

### Data Model Extensions

Data models are `public struct` — can be extended with computed properties:

```swift
extension OpenClawChatMessage {
    var isUserMessage: Bool {
        role.lowercased() == "user"
    }
}
```

## Sealed Components (Cannot Extend)

| Component | Reason |
|-----------|-------|
| `OpenClawChatViewModel` | `final class` — cannot subclass |
| `OpenClawChatView` | `struct` — not inheritable |
| `handleAgentEvent(_:)` | `private` — cannot override |
| `streamingAssistantText` | `private(set)` — cannot write externally |
| `pendingToolCallsById` | `private` |
| All View structs | `struct` (not inheritable) |
| `ChatComposerNSTextView` | `private final` |
| `ChatMarkdownStyle` | `private` |

**Workaround:** Copy `ChatViewModel.swift` locally and modify directly (see Streaming Implementation section).

## Streaming Implementation

### Problem

The `handleAgentEvent` method in `OpenClawChatViewModel` only uses `text` field (full content), ignoring `delta` field. This causes streaming text to appear all at once instead of incrementally.

### Server sends both fields

```
agent data: {
    "text": "完整累积内容...",
    "delta": "本次新增的增量内容..."
}
```

### Solution: Local Copy of ChatViewModel

**Status: On Hold (暂存)**

The attempt to copy `ChatViewModel.swift` locally and modify `handleAgentEvent` was unsuccessful. The following issues were encountered:

1. **ChatViewModel.swift alone is insufficient** - It depends on OpenClawKit types (`OpenClawChatMessage`, `OpenClawChatTransport`, etc.) that are imported from OpenClawKit
2. **ChatView.swift cannot be copied locally** - It depends on `internal` components (`OpenClawChatTheme`, `OpenClawChatComposer`, etc.) that are not accessible outside OpenClawKit
3. **Struct inheritance is not possible** - `OpenClawChatView` is a `struct`, cannot be subclassed

**Current Status:**
- SmartChatApp uses standard OpenClawKit directly (standard mode)
- OpenClawKit is NOT modified
- Delta streaming issue is **on hold**

**Future Options:**
1. Modify `handleAgentEvent` directly in OpenClawKit (minimal change)
2. Wait for upstream OpenClawKit to add delta support
3. Explore alternative architecture if needed