# OpenClawChatUI Module Analysis

**Updated:** 2026-05-12

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
|-----------|--------|
| `OpenClawChatViewModel` | `open class` (can inherit) |
| `handleAgentEvent(_:)` | `open func` (can override) |
| `streamingAssistantText` | `public` (can write) |
| `pendingToolCallsById` | `private` |
| All View structs | `struct` (not inheritable) |
| `ChatComposerNSTextView` | `private final` |
| `ChatMarkdownStyle` | `private` |

## Streaming Implementation Issue

### Problem

The `handleAgentEvent` method ignores the `delta` field, causing streaming text to appear all at once:

```swift
// Current implementation (line ~1194)
case "assistant":
    if let text = evt.data["text"]?.value as? String {
        self.streamingAssistantText = text  // Uses full text, ignores delta
    }
```

### Server sends both `text` (full) and `delta` (incremental)

```
agent data: {
    "text": "完整的累积内容...",
    "delta": "本次新增的增量内容..."
}
```

### Fix Required

Change to use `delta` for incremental updates:

```swift
case "assistant":
    if let delta = evt.data["delta"]?.value as? String {
        self.streamingAssistantText = (self.streamingAssistantText ?? "") + delta
    } else if let text = evt.data["text"]?.value as? String {
        self.streamingAssistantText = text
    }
```

## OpenClawKit Modifications Log

### 2026-05-12

**File:** `OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift`

**Changes (Minimal - Only what's necessary):**

1. **Removed `final` and added `open`** (line ~18)
   - Before: `public final class OpenClawChatViewModel`
   - After: `open class OpenClawChatViewModel`
   - Reason: Allow subclassing for custom streaming behavior

2. **Made `streamingAssistantText` writable** (line ~37)
   - Before: `public private(set) var streamingAssistantText: String?`
   - After: `public var streamingAssistantText: String?`
   - Reason: Allow subclass to update streaming text for delta-based streaming

3. **Changed `handleAgentEvent` to `open func`** (line ~1187)
   - Before: `private func handleAgentEvent(_ evt: OpenClawAgentEventPayload)`
   - After: `open func handleAgentEvent(_ evt: OpenClawAgentEventPayload)`
   - Reason: Allow subclass to override and handle delta-based streaming

**Files modified:**
- `/Users/hai/Code/openclaw/apps/shared/OpenClawKit/Sources/OpenClawChatUI/ChatViewModel.swift`

**Build status:** BUILD SUCCEEDED

**Delta-based streaming implementation:**

Streaming fix is implemented in local `ChatViewModel.swift` (SmartChatApp), NOT in OpenClawKit base class:

```swift
// SmartChatApp/SmartChatApp/Features/Chat/ChatViewModel.swift
public class ChatViewModel: OpenClawChatViewModel {
    open override func handleAgentEvent(_ evt: OpenClawAgentEventPayload) {
        if evt.stream == "assistant" {
            if let delta = evt.data["delta"]?.value as? String {
                self.streamingAssistantText = (self.streamingAssistantText ?? "") + delta
            } else if let text = evt.data["text"]?.value as? String {
                self.streamingAssistantText = text
            }
        } else {
            super.handleAgentEvent(evt)
        }
    }
}
```

This approach:
- Keeps OpenClawKit base class minimal (only `open` modifiers and writable `streamingAssistantText`)
- Allows SmartChatApp to use delta-based streaming
- Other apps using OpenClawKit can still use the base class behavior