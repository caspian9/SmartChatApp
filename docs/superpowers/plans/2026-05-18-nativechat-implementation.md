# NativeChatView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a Telegram-style native chat interface with session selector, message bubbles, and basic input.

**Architecture:** NativeChatView uses TCA pattern with NativeChatViewModel managing state. SessionTabBar provides horizontal session selection. MessageBubbleView renders individual messages. ChatInputView handles text input and send.

**Tech Stack:** SwiftUI, TCA, OpenClawChatTransport

---

## File Structure

- **Create:** `SmartChatApp/Features/NativeChat/NativeChatView.swift` — Main container view
- **Create:** `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` — TCA ViewModel
- **Create:** `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` — Message bubble component
- **Create:** `SmartChatApp/Features/NativeChat/ChatInputView.swift` — Input component
- **Create:** `SmartChatApp/Features/NativeChat/SessionTabBar.swift` — Session selector
- **Modify:** `SmartChatApp/Features/Home/HomeView.swift` — Add navigation to NativeChatView

---

## Task 1: Create SessionTabBar Component

**Files:**
- Create: `SmartChatApp/Features/NativeChat/SessionTabBar.swift`

- [ ] **Step 1: Create SessionTabBar.swift**

```swift
import SwiftUI
import OpenClawChatUI

struct SessionTabBar: View {
    let sessions: [OpenClawChatSessionEntry]
    @Binding var selectedSession: OpenClawChatSessionEntry?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: selectedSession?.key == session.key,
                        action: {
                            selectedSession = session
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(hex: "1E1E1E"))
    }
}

struct SessionTab: View {
    let session: OpenClawChatSessionEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(session.displayName ?? String(session.key.prefix(8)))
                .font(.caption)
                .foregroundColor(isSelected ? .white : .gray)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color(hex: "10A37F") : Color(hex: "2A2A2A"))
                .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/SessionTabBar.swift
git commit -m "feat: add SessionTabBar for NativeChat

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 2: Create MessageBubbleView Component

**Files:**
- Create: `SmartChatApp/Features/NativeChat/MessageBubbleView.swift`

- [ ] **Step 1: Create MessageBubbleView.swift**

```swift
import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isOutgoing ? Color(hex: "10A37F") : Color(hex: "1E1E1E"))
                    .cornerRadius(12)

                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            if !message.isOutgoing {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func formatTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let isOutgoing: Bool
    let timestamp: Date

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/MessageBubbleView.swift
git commit -m "feat: add MessageBubbleView for NativeChat

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 3: Create ChatInputView Component

**Files:**
- Create: `SmartChatApp/Features/NativeChat/ChatInputView.swift`

- [ ] **Step 1: Create ChatInputView.swift**

```swift
import SwiftUI

struct ChatInputView: View {
    @Binding var inputText: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("输入消息...", text: $inputText)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "2A2A2A"))
                .cornerRadius(20)
                .foregroundColor(.white)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color(hex: "10A37F"))
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "1E1E1E"))
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/ChatInputView.swift
git commit -m "feat: add ChatInputView for NativeChat

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 4: Create NativeChatViewModel

**Files:**
- Create: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`

- [ ] **Step 1: Create NativeChatViewModel.swift**

```swift
import ComposableArchitecture
import Foundation
import OpenClawChatUI

@Reducer
struct NativeChatViewModel {
    struct State: Equatable {
        var sessions: [OpenClawChatSessionEntry] = []
        var selectedSession: OpenClawChatSessionEntry?
        var messages: [ChatMessage] = []
        var inputText: String = ""
        var isLoading: Bool = false
        var isSending: Bool = false
    }

    enum Action: Equatable {
        case loadSessions
        case loadedSessions([OpenClawChatSessionEntry])
        case selectSession(OpenClawChatSessionEntry)
        case updateInputText(String)
        case sendMessage
        case loadHistory
        case loadedHistory([ChatMessage])
        case receiveMessage(ChatMessage)
    }

    @Dependency(\.continuousClock) var clock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(100))
                    await send(.loadedSessions([]))
                }

            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                if state.selectedSession == nil, let first = sessions.first {
                    state.selectedSession = first
                }
                return .none

            case .selectSession(let session):
                state.selectedSession = session
                return .send(.loadHistory)

            case .updateInputText(let text):
                state.inputText = text
                return .none

            case .sendMessage:
                guard !state.inputText.isEmpty,
                      let session = state.selectedSession else {
                    return .none
                }
                let text = state.inputText
                let message = ChatMessage(
                    id: UUID().uuidString,
                    text: text,
                    isOutgoing: true,
                    timestamp: Date()
                )
                state.messages.append(message)
                state.inputText = ""
                return .none

            case .loadHistory:
                return .run { send in
                    await send(.loadedHistory([]))
                }

            case .loadedHistory(let messages):
                state.messages = messages
                return .none

            case .receiveMessage(let message):
                state.messages.append(message)
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
git commit -m "feat: add NativeChatViewModel with TCA

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 5: Create NativeChatView

**Files:**
- Create: `SmartChatApp/Features/NativeChat/NativeChatView.swift`

- [ ] **Step 1: Create NativeChatView.swift**

```swift
import SwiftUI
import ComposableArchitecture

struct NativeChatView: View {
    let store: StoreOf<NativeChatViewModel>

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                SessionTabBar(
                    sessions: store.sessions,
                    selectedSession: Binding(
                        get: { store.selectedSession },
                        set: { if let s = $0 { store.send(.selectSession(s)) } }
                    )
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: store.messages.count) { _, _ in
                    if let lastMessage = store.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            ChatInputView(
                inputText: Binding(
                    get: { store.inputText },
                    set: { store.send(.updateInputText($0)) }
                ),
                onSend: {
                    store.send(.sendMessage)
                }
            )
        }
        .background(Color.black)
        .navigationTitle("NativeChat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.send(.loadSessions)
            store.send(.loadHistory)
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/NativeChatView.swift
git commit -m "feat: add NativeChatView container

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 6: Update HomeView Navigation

**Files:**
- Modify: `SmartChatApp/Features/Home/HomeView.swift`

- [ ] **Step 1: Update HomeView to navigate to NativeChatView**

Add `@State private var showNativeChat = false` and navigation destination:

```swift
NavigationStack {
    VStack(spacing: 40) {
        Spacer()

        HStack(spacing: 20) {
            EntryCard(
                title: "Native Chat",
                icon: "bubble.left.and.bubble.right",
                action: {
                    showNativeChat = true
                }
            )
            // ...
        }
        // ...
    }
    .navigationDestination(isPresented: $showNativeChat) {
        NativeChatView(
            store: StoreOf<NativeChatViewModel>(initialState: NativeChatViewModel.State())
        )
    }
}
```

- [ ] **Step 2: Verify build**

- [ ] **Step 3: Install to device**

- [ ] **Step 4: Commit**

---

## Verification

1. Build succeeds
2. Home screen shows two entry cards
3. NativeChat card navigates to NativeChatView
4. Session tab bar displays sessions
5. Messages display with proper bubbles
6. Input allows text entry and send button