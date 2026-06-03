# NativeChatView Design

## Goal

Implement a Telegram-style native chat interface with:
- Horizontal session selector tabs
- Message bubbles (sent/received)
- Basic text input with send button

## Layout

```
┌─────────────────────────────────────┐
│  ← 返回    NativeChat      Session ▼│
├─────────────────────────────────────┤
│  [Session1] [Session2] [Session3] →│
├─────────────────────────────────────┤
│                                     │
│  ┌─────────┐                        │
│  │ Hello!  │                       │
│  └─────────┘                        │
│                                     │
│           ┌───────────────┐         │
│           │ Hi, how can I│         │
│           │ help you?    │         │
│           └───────────────┘         │
│                                     │
├─────────────────────────────────────┤
│  [输入框....................] [发送]│
└─────────────────────────────────────┘
```

## Components

### 1. NativeChatView
- Main container with NavigationStack
- Contains SessionTabBar, message list, ChatInputView
- Manages navigation title and back button

### 2. SessionTabBar
- Horizontal ScrollView with session tabs
- Each tab shows session displayName or key prefix
- Selected tab highlighted with accent color
- Filters sessions by current device

### 3. MessageBubbleView
- Sent messages: right-aligned, accent background (#10A37F)
- Received messages: left-aligned, dark background (#1E1E1E)
- Rounded corners (12pt)
- Timestamp below message

### 4. ChatInputView
- TextEditor or TextField for input
- Send button (accent color)
- Basic version: text + send only

### 5. NativeChatViewModel (TCA)
- State: sessions, selectedSession, messages, inputText, isLoading
- Action: selectSession, sendMessage, loadHistory
- Uses OpenClawChatTransport for API calls

## Data Flow

```
[User Input] → sendMessage() → OpenClawChatTransport → API
                    ↓
            events() AsyncStream
                    ↓
            Update messages state
                    ↓
            Render MessageBubbleView
```

## OpenClawChatTransport Usage

```swift
// Send message
try await transport.sendMessage(
    sessionKey: selectedSession.key,
    message: inputText,
    thinking: "",
    idempotencyKey: UUID().uuidString,
    attachments: []
)

// Listen for events
for await event in transport.events() {
    switch event {
    case .chat(let payload):
        // Handle chat event
    case .sessionMessage(let payload):
        // Handle session message
    default:
        break
    }
}

// Load history
let history = try await transport.requestHistory(sessionKey: selectedSession.key)
```

## Session Filtering

Sessions should be filtered to show only those matching current device context. Implementation uses existing session list from SessionManager.

## Implementation Files

- Create: `SmartChatApp/Features/NativeChat/NativeChatView.swift`
- Create: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`
- Create: `SmartChatApp/Features/NativeChat/MessageBubbleView.swift`
- Create: `SmartChatApp/Features/NativeChat/ChatInputView.swift`
- Create: `SmartChatApp/Features/NativeChat/SessionTabBar.swift`

## Future Enhancements (Recorded in Memory)

- Local message caching
- Enhanced input (attachments, voice, emoji)