# NativeChatViewModel Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 1525-line `NativeChatViewModel.swift` into a thin coordinator plus four single-responsibility collaborators, move pure formatters/converters to `Core/Utilities/`, and consolidate value types in `Models/`. **Zero functional change.**

**Architecture:** VM stays `@MainActor @Observable`, owns state plus four collaborators (`SessionCoordinator`, `HistoryLoader`, `EventInterpreter`, `MessageReceiver`). Each collaborator holds a weak ref to VM and writes back to its `@Observable` state. Pure functions move to `static` helpers. SDK's public `AnyCodable+Helpers` extension replaces our private extractors.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17 `@Observable` macro, OpenClawKit SDK, OpenClawChatUI SDK, XcodeGen

---

## File Structure

**New files:**
- `SmartChatApp/Models/SessionKey.swift` — value type parsing `agent:channel:label:uuid`
- `SmartChatApp/Core/Utilities/MessageFormatters.swift` — 4 static formatter methods
- `SmartChatApp/Core/Utilities/ChatMessageConverter.swift` — `ChatMessage` ↔ `OpenClawChatMessage` static helpers
- `SmartChatApp/Features/NativeChat/Internal/SessionCoordinator.swift` — `@MainActor` collaborator, session lifecycle
- `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift` — `@MainActor` collaborator, history loading + reentrancy lock
- `SmartChatApp/Features/NativeChat/Internal/EventInterpreter.swift` — `@MainActor` collaborator, transport event → ChatMessage
- `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift` — `@MainActor` collaborator, message dedup/reception
- `SmartChatAppTests/SessionKeyTests.swift` — unit tests for SessionKey
- `SmartChatAppTests/ChatMessageConverterTests.swift` — unit tests for converter

**Moved files:**
- `SmartChatApp/Cards/CardModels.swift` → `SmartChatApp/Models/CardData.swift` (no content change)

**Modified files:**
- `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` — shrink to ~280 lines (state + public API + forwarders)
- `SmartChatApp/Features/NativeChat/SessionPickerView.swift` — use `SessionKey.parse(...)` instead of inline `key.split(":")`
- `SmartChatAppTests/NativeChatViewModelFormatterTests.swift` — change `sut.foo(...)` → `MessageFormatters.foo(...)`

**Unchanged files (verify only):**
- `SmartChatApp/Features/NativeChat/NativeChatView.swift` — public API preserved
- `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` — public API preserved
- `SmartChatApp/Features/NativeChat/ChatInputView.swift` — public API preserved
- `SmartChatApp/Features/NativeChat/SessionTabBar.swift` — public API preserved
- `SmartChatApp/Core/Services/CardRegistry.swift` — same module, no import change needed
- `SmartChatApp/Cards/{Music,Video,Button,Image}CardView.swift` — same module, no import change needed

---

## Build/Test Commands Reference

These are used throughout the plan. Run from `/Users/hai/Code/SmartChatApp`.

- **Regenerate Xcode project** (after adding/moving files):
  ```bash
  xcodegen generate
  ```
- **Build app**:
  ```bash
  make build
  ```
  (Runs `xcodegen generate` + `xcodebuild -skipMacroValidation -scheme SmartChatApp -destination "platform=iOS,name=$(DEVICE_NAME)" -allowProvisioningUpdates build`.)
- **Run all unit tests**:
  ```bash
  xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
  ```
- **Run a single test class**:
  ```bash
  xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
    -only-testing:SmartChatAppTests/SessionKeyTests
  ```

---

## Task 1: Add `Models/SessionKey.swift` with unit tests

**Files:**
- Create: `SmartChatApp/Models/SessionKey.swift`
- Create: `SmartChatAppTests/SessionKeyTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `SmartChatAppTests/SessionKeyTests.swift`:

```swift
import XCTest
@testable import SmartChatApp

final class SessionKeyTests: XCTestCase {

    func testParse_fullKey_extractsAllFourParts() {
        let k = SessionKey.parse("agent:myagent:mychannel:mylabel:abcdef12-3456-7890")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertEqual(k.channel, "mychannel")
        XCTAssertEqual(k.label, "mylabel")
        XCTAssertEqual(k.uuid, "abcdef12-3456-7890")
        XCTAssertEqual(k.raw, "agent:myagent:mychannel:mylabel:abcdef12-3456-7890")
    }

    func testParse_threePartKey_labelAndUuidCollide_returnsLabelAsUuid() {
        // Existing behavior: when 4th segment is also the label, the
        // uuid fallback returns it. Document the collision.
        let k = SessionKey.parse("agent:myagent:mychannel:onlylabel")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertEqual(k.channel, "mychannel")
        XCTAssertEqual(k.label, "onlylabel")
        XCTAssertEqual(k.uuid, "onlylabel")
    }

    func testParse_twoPartKey_missingChannelAndLabel_areNil() {
        let k = SessionKey.parse("agent:myagent")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertNil(k.channel)
        XCTAssertNil(k.label)
        // uuid falls back to the last 8 chars of the raw key
        XCTAssertEqual(k.uuid, "t:myagen"  // String("agent:myagent".suffix(8))
            .replacingOccurrences(of: "agent:myagen", with: "t:myagen"))
    }

    func testParse_emptySegments_areTreatedAsNil() {
        let k = SessionKey.parse("agent:myagent::  :")
        XCTAssertEqual(k.agentId, "myagent")
        XCTAssertNil(k.channel)
        XCTAssertNil(k.label)
        XCTAssertNil(k.uuid)
    }

    func testMakeNew_producesAgentPrefixAndLowercaseUuid() {
        let s = SessionKey.makeNew(agentId: "MyAgent", clientLabel: "smartchatapp")
        let k = SessionKey.parse(s)
        XCTAssertEqual(k.agentId, "MyAgent")
        XCTAssertEqual(k.label, "smartchatapp")
        XCTAssertNotNil(k.uuid)
        XCTAssertEqual(k.uuid, k.uuid?.lowercased()) // already lowercased
        XCTAssertTrue(s.hasPrefix("agent:MyAgent:smartchatapp:"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error)**

```bash
xcodegen generate
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/SessionKeyTests
```

Expected: build fails with `cannot find 'SessionKey' in scope`.

- [ ] **Step 3: Create empty `SessionKey` type to fix compile error**

Create `SmartChatApp/Models/SessionKey.swift`:

```swift
import Foundation

struct SessionKey: Equatable {
    let raw: String
    let agentId: String?
    let channel: String?
    let label: String?
    let uuid: String?
}
```

- [ ] **Step 4: Run tests, expect compile error (methods missing)**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/SessionKeyTests
```

Expected: build fails with `type 'SessionKey' has no member 'parse'` and `'makeNew'`.

- [ ] **Step 5: Implement `parse` and `makeNew`**

Replace `SmartChatApp/Models/SessionKey.swift` with:

```swift
import Foundation

struct SessionKey: Equatable {
    let raw: String
    let agentId: String?
    let channel: String?
    let label: String?
    let uuid: String?

    static func parse(_ raw: String) -> SessionKey {
        let parts = raw.split(separator: ":")
        func segment(_ i: Int) -> String? {
            guard i < parts.count else { return nil }
            let s = String(parts[i]).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let label = segment(3)
        // uuid: prefer segment(3) (real uuid) over last-8-of-raw fallback
        // when segment(3) looks like a uuid. The original VM code at
        // NativeChatViewModel extractSessionUuid returned the label
        // as uuid when only 3 segments were present; preserve that.
        let uuid: String? = {
            if let label, label.contains("-") || label.count == 36 {
                return label
            }
            return label ?? String(raw.suffix(8))
        }()
        return SessionKey(
            raw: raw,
            agentId: segment(1),
            channel: segment(2),
            label: label,
            uuid: uuid
        )
    }

    /// Build a new session key for createSession: "agent:<agentId>:<clientLabel>:<uuid>".
    static func makeNew(agentId: String, clientLabel: String) -> String {
        "agent:\(agentId):\(clientLabel):\(UUID().uuidString.lowercased())"
    }
}
```

- [ ] **Step 6: Adjust the `testParse_twoPartKey_missingChannelAndLabel_areNil` test**

The original draft had a hacky comparison. Replace the body of that test with:

```swift
func testParse_twoPartKey_missingChannelAndLabel_areNil() {
    let k = SessionKey.parse("agent:myagent")
    XCTAssertEqual(k.agentId, "myagent")
    XCTAssertNil(k.channel)
    XCTAssertNil(k.label)
    // uuid falls back to the last 8 chars of the raw key (preserves
    // the existing behavior of NativeChatViewModel.extractSessionUuid).
    XCTAssertEqual(k.uuid, String("agent:myagent".suffix(8)))
}
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/SessionKeyTests
```

Expected: 5 tests pass.

- [ ] **Step 8: Commit**

```bash
git add SmartChatApp/Models/SessionKey.swift SmartChatAppTests/SessionKeyTests.swift SmartChatApp.xcodeproj
git commit -m "feat(models): add SessionKey value type with parse/makeNew"
```

---

## Task 2: Add `Core/Utilities/MessageFormatters.swift` and relocate formatter tests

**Files:**
- Create: `SmartChatApp/Core/Utilities/MessageFormatters.swift`
- Modify: `SmartChatAppTests/NativeChatViewModelFormatterTests.swift` (lines 17, 22, 28, 32, 36, 46, 57, 61, 65, 78, 82, 86, 90, 95, 102, 106, 110, 114, 118, 122, 127, 131, 138, 145, 152)

- [ ] **Step 1: Create `MessageFormatters` with `formatToolCallText` and `formatToolResultText`**

Create `SmartChatApp/Core/Utilities/MessageFormatters.swift`:

```swift
import Foundation

enum MessageFormatters {
    /// Builds a short human-readable label for a tool call: "name: args".
    /// Falls back to a one-line JSON dump of args so the bubble has something
    /// to show even when no friendly field is present.
    static func formatToolCallText(name: String, args: Any?) -> String {
        if name.isEmpty { return "" }
        guard let args else { return name }
        if let str = args as? String, !str.isEmpty {
            return "\(name): \(str)"
        }
        if let dict = args as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        if let arr = args as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        return name
    }

    /// Pretty-prints a tool result payload. JSON values get indented; raw
    /// strings pass through. The MessageBubbleView will further pretty-print
    /// anything it sees for `role == "toolResult"`, so this stays minimal.
    static func formatToolResultText(result: Any?) -> String {
        guard let result else { return "" }
        if let str = result as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: result)
    }
}
```

- [ ] **Step 2: Update the two affected tests to call the new API**

In `SmartChatAppTests/NativeChatViewModelFormatterTests.swift`, find each `sut.formatToolCallText(` and `sut.formatToolResultText(` and replace with `MessageFormatters.formatToolCallText(` / `MessageFormatters.formatToolResultText(`. There are 6 `formatToolCallText` test calls (lines 17, 22, 28, 32, 36, 46) and 3 `formatToolResultText` test calls (lines 57, 61, 65).

- [ ] **Step 3: Run the formatter tests, expect failures (only 2 of 4 methods moved so far)**

```bash
xcodegen generate
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/NativeChatViewModelFormatterTests
```

Expected: the 9 tests moved so far pass; the remaining 13 tests calling `sut.formatAnyCodableValue(...)` fail to compile (method still exists on VM, so they actually pass — that's fine; we haven't moved those yet).

Verify: all 22 tests still pass (because VM still has all 4 methods).

- [ ] **Step 4: Add `formatAnyCodableValue` and `formatToolCallBubbleText` to `MessageFormatters`**

Append to `SmartChatApp/Core/Utilities/MessageFormatters.swift`:

```swift
extension MessageFormatters {
    static func formatAnyCodableValue(_ value: Any) -> String {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            if first.count > 160 { return String(first.prefix(157)) + "…" }
            return first
        }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let array = value as? [Any] {
            let items = array.compactMap { MessageFormatters.formatAnyCodableValue($0) }
            guard !items.isEmpty else { return "" }
            let preview = items.prefix(3).joined(separator: ", ")
            return items.count > 3 ? "\(preview)…" : preview
        }
        if let dict = value as? [String: Any] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let label = dict[key] {
                    let str = MessageFormatters.formatAnyCodableValue(label)
                    if !str.isEmpty { return str }
                }
            }
        }
        if let dict = value as? [String: AnyCodable] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let anyCodable = dict[key] {
                    let formatted = MessageFormatters.formatAnyCodableValue(anyCodable.value)
                    if !formatted.isEmpty { return formatted }
                }
            }
            // Generic scan for first non-empty string value
            for (_, anyCodable) in dict {
                let formatted = MessageFormatters.formatAnyCodableValue(anyCodable.value)
                if !formatted.isEmpty {
                    return formatted
                }
            }
        }
        return ""
    }

    /// Renders a toolCall bubble's text. Three forms depending on what's available:
    /// ```
    /// // 1. history / legacy verbose=on — full key: value list from args
    /// ToolCall: <name>
    /// command: <cmd>
    /// timeout: <timeout>
    ///
    /// // 2. modern `item` event with meta — second line shows the action summary
    /// ToolCall: <name>
    /// with: <meta>
    ///
    /// // 3. modern `item` event without meta — name only
    /// ToolCall: <name>
    /// ```
    static func formatToolCallBubbleText(name: String, arguments: AnyCodable?, meta: String? = nil) -> String {
        guard !name.isEmpty else { return "" }
        var callText = "ToolCall: \(name)"
        if let arguments {
            var argsLines: [String] = []
            let appendArgLine: (String, Any) -> Void = { key, value in
                let valueStr: String
                if key == "command", let str = value as? String {
                    valueStr = str
                } else {
                    valueStr = MessageFormatters.formatAnyCodableValue(value)
                }
                if !valueStr.isEmpty {
                    argsLines.append("\(key): \(valueStr)")
                }
            }
            if let dict = arguments.value as? [String: AnyCodable] {
                for (key, anyCodable) in dict {
                    appendArgLine(key, anyCodable.value)
                }
            } else if let dict = arguments.value as? [String: Any] {
                for (key, value) in dict {
                    appendArgLine(key, value)
                }
            }
            if !argsLines.isEmpty {
                callText += "\n" + argsLines.joined(separator: "\n")
                return callText
            }
        }
        if let meta, !meta.isEmpty {
            callText += "\nwith: \(meta)"
        }
        return callText
    }
}
```

> **Note for the implementer:** `MessageFormatters` is a `static`-only `enum` in the app target (`Core/Utilities/`), **not** an extension on any SDK type. This is a deliberate choice for two reasons: (1) the formatter output is app-specific UI text (e.g., `"ToolCall: \(name)"` + key: value lines), tied to our bubble view's visual design, so it does not belong in the SDK; (2) keeping it in the app means future SDK removal only touches the call sites (Task 8's `EventInterpreter`, Task 7's `HistoryLoader`, Task 3's `ChatMessageConverter`), never this file. If we later decide to upgrade tool display to use SDK's `ToolDisplayRegistry`, the replacement happens here, inside `formatToolCallBubbleText` — callers don't change.

- [ ] **Step 5: Update the remaining 13 tests to call the new API**

In `SmartChatAppTests/NativeChatViewModelFormatterTests.swift`, find each `sut.formatAnyCodableValue(` (13 calls) and replace with `MessageFormatters.formatAnyCodableValue(`.

- [ ] **Step 6: Run the formatter tests, expect 22 passes**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/NativeChatViewModelFormatterTests
```

Expected: 22 tests pass (proves `MessageFormatters` is byte-equivalent to the VM's instance methods).

- [ ] **Step 7: Remove the now-duplicate methods from `NativeChatViewModel`**

In `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`:
- Delete the `func formatAnyCodableValue(_ value: Any) -> String { ... }` block (lines 1388–1431)
- Delete the `func formatToolCallText(name: String, args: Any?) -> String { ... }` block (lines 1436–1455)
- Delete the `func formatToolCallBubbleText(name: String, arguments: AnyCodable?, meta: String? = nil) -> String { ... }` block (lines 1475–1511)
- Delete the `func formatToolResultText(result: Any?) -> String { ... }` block (lines 1516–1524)

(Keep the `extract*` / `summarizeData` / `formatValue` / `summarizeAny` / `unwrapAnyCodable` / `createOpenClawChatMessage` methods for now — those move in later tasks.)

- [ ] **Step 8: Build the app, expect 0 errors (the VM's `receiveMessage` and `handleTransportEvent` still call these methods, but on themselves)**

In the VM, the call sites are `self.formatToolCallBubbleText(...)` etc. After deleting the methods, the compiler will complain.

**Quick fix**: replace the `self.format*` calls with `MessageFormatters.format*`:

In `NativeChatViewModel.swift`:
- Line 547: `formatToolCallBubbleText(name: name, arguments: contentItem.arguments)` → `MessageFormatters.formatToolCallBubbleText(name: name, arguments: contentItem.arguments)`
- Line 1017: `formatToolCallBubbleText(name: toolName, arguments: data["args"])` → `MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])`
- Line 1039: `formatToolCallBubbleText(name: toolName, arguments: data["args"])` → `MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])`
- Line 1060: `formatToolResultText(result: resultValue)` → `MessageFormatters.formatToolResultText(result: resultValue)`
- Line 1115: `formatToolCallBubbleText(name: name, arguments: data["args"], meta: meta)` → `MessageFormatters.formatToolCallBubbleText(name: name, arguments: data["args"], meta: meta)`

Use `replace_all: true` for `formatToolCallBubbleText(` → `MessageFormatters.formatToolCallBubbleText(` (4 occurrences).
And `formatToolResultText(result:` → `MessageFormatters.formatToolResultText(result:` (1 occurrence).

- [ ] **Step 9: Build the app, verify it compiles**

```bash
make build
```

Expected: build succeeds. App installs to device if connected (won't be installed by this command on a CI machine — that's fine, we just need the build to succeed).

- [ ] **Step 10: Commit**

```bash
git add SmartChatApp/Core/Utilities/MessageFormatters.swift \
        SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatAppTests/NativeChatViewModelFormatterTests.swift \
        SmartChatApp.xcodeproj
git commit -m "refactor(utilities): extract MessageFormatters from NativeChatViewModel"
```

---

## Task 3: Add `Core/Utilities/ChatMessageConverter.swift` with unit tests

**Files:**
- Create: `SmartChatApp/Core/Utilities/ChatMessageConverter.swift`
- Create: `SmartChatAppTests/ChatMessageConverterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `SmartChatAppTests/ChatMessageConverterTests.swift`:

```swift
import XCTest
@testable import SmartChatApp
@testable import OpenClawProtocol
import OpenClawChatUI

final class ChatMessageConverterTests: XCTestCase {

    // MARK: - toChatMessage

    func testToChatMessage_textOnly_returnsAssistantRole() {
        let content = [OpenClawChatMessageContent(
            type: "text", text: "hello", thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 1_700_000_000_000, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.text, "hello")
        XCTAssertEqual(chat?.role, "assistant")
        XCTAssertEqual(chat?.id, msg.id.uuidString)
    }

    func testToChatMessage_emptyText_returnsNil() {
        let content = [OpenClawChatMessageContent(
            type: "text", text: "", thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        XCTAssertNil(ChatMessageConverter.toChatMessage(from: msg))
    }

    func testToChatMessage_thinkingOnly_roleIsThinking() {
        let content = [OpenClawChatMessageContent(
            type: "thinking", text: nil, thinking: "let me think",
            thinkingSignature: nil, mimeType: nil, fileName: nil, content: nil)]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "assistant", content: content,
            timestamp: 0, toolCallId: nil, toolName: nil,
            usage: nil, stopReason: nil, errorMessage: nil)
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.role, "thinking")
        XCTAssertEqual(chat?.text, "let me think")
    }

    func testToChatMessage_toolCallOnly_roleIsToolCall() {
        let content = [OpenClawChatMessageContent(
            type: "toolCall", text: nil, thinking: nil, thinkingSignature: nil,
            mimeType: nil, fileName: nil, content: nil,
            id: "tc-1", name: "read_file", arguments: AnyCodable(["path": "x.txt"]))]
        let msg = OpenClawChatMessage(
            id: UUID(), role: "tool", content: content,
            timestamp: 0, toolCallId: "tc-1", toolName: "read_file",
            usage: nil, stopReason: nil, errorMessage: nil)
        let chat = ChatMessageConverter.toChatMessage(from: msg)
        XCTAssertEqual(chat?.role, "toolCall")
        XCTAssertTrue(chat?.text.contains("read_file") ?? false)
    }

    // MARK: - toOpenClawChatMessage

    func testToOpenClawChatMessage_validUuid_returnsMessage() {
        let chat = ChatMessage(
            id: "11111111-2222-3333-4444-555555555555",
            text: "hi", timestamp: Date(timeIntervalSince1970: 1700),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        let msg = ChatMessageConverter.toOpenClawChatMessage(from: chat)
        XCTAssertEqual(msg?.role, "user")
        XCTAssertEqual(msg?.content.first?.text, "hi")
        XCTAssertEqual(msg?.timestamp, 1_700_000)  // ms (1700 sec * 1000)
    }

    func testToOpenClawChatMessage_invalidUuid_returnsNil() {
        let chat = ChatMessage(
            id: "not-a-uuid", text: "x", timestamp: Date(),
            role: "user", state: "final", runId: nil, seq: nil,
            startedAt: nil, endedAt: nil, livenessState: nil,
            toolCallId: nil, toolName: nil, stopReason: nil, isFresh: true)
        XCTAssertNil(ChatMessageConverter.toOpenClawChatMessage(from: chat))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail (compile error)**

```bash
xcodegen generate
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/ChatMessageConverterTests
```

Expected: build fails with `cannot find 'ChatMessageConverter' in scope`.

- [ ] **Step 3: Create `ChatMessageConverter` with both methods**

Create `SmartChatApp/Core/Utilities/ChatMessageConverter.swift`:

```swift
import Foundation
import OpenClawChatUI
import OpenClawProtocol

enum ChatMessageConverter {
    /// OpenClawChatMessage → ChatMessage, applying the project's content
    /// extraction rules (text → assistant, thinking → thinking, toolCall →
    /// toolCall). Returns nil when the message has no displayable text.
    /// Body mirrors the `compactMap { msg -> ChatMessage? in ... }` blocks
    /// previously duplicated 3× in NativeChatViewModel.loadHistory.
    static func toChatMessage(from msg: OpenClawChatMessage) -> ChatMessage? {
        var text = ""
        var role = msg.role
        for contentItem in msg.content {
            if let t = contentItem.text, !t.isEmpty {
                text = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if text.isEmpty {
            for contentItem in msg.content {
                if let thinking = contentItem.thinking, !thinking.isEmpty {
                    text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    role = "thinking"
                    break
                }
            }
        }
        var hasToolCall = false
        var toolCallText = ""
        for contentItem in msg.content {
            if contentItem.type == "toolCall", let name = contentItem.name {
                let callText = MessageFormatters.formatToolCallBubbleText(
                    name: name, arguments: contentItem.arguments)
                guard !callText.isEmpty else { continue }
                hasToolCall = true
                if toolCallText.isEmpty {
                    toolCallText = callText
                } else {
                    toolCallText += "\n\n" + callText
                }
            }
        }
        if hasToolCall {
            if text.isEmpty {
                text = toolCallText
                role = "toolCall"
            } else {
                text = text + "\n\n" + toolCallText
            }
        }
        guard !text.isEmpty else { return nil }
        let ts = msg.timestamp ?? 0
        return ChatMessage(
            id: msg.id.uuidString,
            text: text,
            timestamp: Date(timeIntervalSince1970: ts / 1000),
            role: role,
            state: "final",
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            livenessState: nil,
            inputTokens: msg.usage?.input,
            outputTokens: msg.usage?.output,
            cacheRead: msg.usage?.cacheRead,
            cacheWrite: msg.usage?.cacheWrite,
            toolCallId: msg.toolCallId,
            toolName: msg.toolName,
            stopReason: msg.stopReason
        )
    }

    /// ChatMessage → OpenClawChatMessage (cache writer). Returns nil for
    /// non-UUID ids (cache requires a stable UUID primary key).
    /// Mirrors the `createOpenClawChatMessage(from:)` previously on the VM.
    static func toOpenClawChatMessage(from chatMessage: ChatMessage) -> OpenClawChatMessage? {
        guard let uuid = UUID(uuidString: chatMessage.id) else { return nil }
        var usage: OpenClawChatUsage? = nil
        if chatMessage.inputTokens != nil || chatMessage.outputTokens != nil
            || chatMessage.cacheRead != nil || chatMessage.cacheWrite != nil {
            var usageData: [String: AnyCodable] = [:]
            if let input = chatMessage.inputTokens { usageData["input"] = AnyCodable(input) }
            if let output = chatMessage.outputTokens { usageData["output"] = AnyCodable(output) }
            if let cr = chatMessage.cacheRead { usageData["cacheRead"] = AnyCodable(cr) }
            if let cw = chatMessage.cacheWrite { usageData["cacheWrite"] = AnyCodable(cw) }
            if let data = try? JSONEncoder().encode(usageData),
               let decoded = try? JSONDecoder().decode(OpenClawChatUsage.self, from: data) {
                usage = decoded
            }
        }
        return OpenClawChatMessage(
            id: uuid,
            role: chatMessage.role,
            content: [OpenClawChatMessageContent(
                type: "text", text: chatMessage.text, thinking: nil,
                thinkingSignature: nil, mimeType: nil, fileName: nil,
                content: nil, id: nil, name: nil, arguments: nil)],
            timestamp: chatMessage.timestamp.timeIntervalSince1970 * 1000,
            toolCallId: chatMessage.toolCallId,
            toolName: chatMessage.toolName,
            usage: usage,
            stopReason: chatMessage.stopReason
        )
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:SmartChatAppTests/ChatMessageConverterTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Core/Utilities/ChatMessageConverter.swift \
        SmartChatAppTests/ChatMessageConverterTests.swift \
        SmartChatApp.xcodeproj
git commit -m "feat(utilities): add ChatMessageConverter (de-dups 3× conversion logic)"
```

---

## Task 4: Move `Cards/CardModels.swift` → `Models/CardData.swift`

**Files:**
- Delete: `SmartChatApp/Cards/CardModels.swift`
- Create: `SmartChatApp/Models/CardData.swift`

- [ ] **Step 1: Move the file using `git mv` (preserves history)**

```bash
git mv SmartChatApp/Cards/CardModels.swift SmartChatApp/Models/CardData.swift
```

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `SmartChatApp.xcodeproj` is regenerated with `CardData.swift` in the new location.

- [ ] **Step 3: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds. All consumers (`CardRegistry.swift`, the 4 card views) are in the same module, so no import changes are needed.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 44 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Cards/CardModels.swift SmartChatApp/Models/CardData.swift SmartChatApp.xcodeproj
git commit -m "refactor(models): move CardModels.swift to Models/CardData.swift"
```

---

## Task 5: Refactor `SessionPickerView.swift` to use `SessionKey`

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/SessionPickerView.swift` (lines 15-38)

- [ ] **Step 1: Replace the three `extract*` helpers with `SessionKey.parse`**

In `SmartChatApp/Features/NativeChat/SessionPickerView.swift`, replace lines 15-38:

```swift
private func extractAgentId(from key: String) -> String {
    let parts = key.split(separator: ":")
    if parts.count >= 2 {
        return String(parts[1])
    }
    return "Unknown"
}

private func extractChannel(from key: String) -> String {
    let parts = key.split(separator: ":")
    if parts.count >= 3 {
        let channel = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return channel.isEmpty ? "Unknown" : channel
    }
    return "Unknown"
}

private func extractSessionUuid(from key: String) -> String {
    let parts = key.split(separator: ":")
    if parts.count >= 4 {
        return String(parts[3])
    }
    return String(key.suffix(8))
}
```

with:

```swift
private func extractAgentId(from key: String) -> String {
    SessionKey.parse(key).agentId ?? "Unknown"
}

private func extractChannel(from key: String) -> String {
    SessionKey.parse(key).channel ?? "Unknown"
}

private func extractSessionUuid(from key: String) -> String {
    SessionKey.parse(key).uuid ?? String(key.suffix(8))
}
```

- [ ] **Step 2: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds. The behavior is identical (segment[1] / segment[2] / segment[3-or-8] is exactly what `SessionKey.parse` returns).

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/NativeChat/SessionPickerView.swift
git commit -m "refactor(nativechat): use SessionKey.parse in SessionPickerView"
```

---

## Task 6: Extract `MessageReceiver` from `NativeChatViewModel`

**Files:**
- Create: `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift`
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (lines 700-712, 714-799)

- [ ] **Step 1: Create the `MessageReceiver` collaborator**

Create `SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift`:

```swift
import SwiftUI
import OpenClawChatUI

@MainActor
final class MessageReceiver {
    weak var viewModel: NativeChatViewModel?

    /// Apply an incoming `ChatMessage` to the view-model's `messages` array.
    /// Three merge paths: id-match (streaming update), role+text+timestamp
    /// similar-match (cache ↔ streaming id mismatch), or fresh insert.
    /// Mirrors `NativeChatViewModel.receiveMessage` from the pre-refactor VM.
    func receiveMessage(_ message: ChatMessage) {
        guard let vm = viewModel else { return }
        if let existingIndex = vm.messages.firstIndex(where: { $0.id == message.id }) {
            var existingMessage = vm.messages[existingIndex]
            AppLogger.log("receiveMessage update - id: \(String(message.id.prefix(8))), existingIndex: \(existingIndex), newText len: \(message.text.count), existingText len: \(existingMessage.text.count), state: \(message.state)", category: .nativeChat)
            if !message.text.isEmpty {
                existingMessage.text = message.text
                AppLogger.log("receiveMessage updated text, new len: \(existingMessage.text.count), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat)
            } else {
                AppLogger.log("receiveMessage SKIPPED text update (empty), prev state: \(existingMessage.state), new state: \(message.state)", category: .nativeChat, level: .warning)
            }
            existingMessage.state = message.state
            if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
            if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
            if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
            if message.seq != nil { existingMessage.seq = message.seq }
            if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
            if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
            if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
            if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
            vm.messages[existingIndex] = existingMessage
            vm.scrollTrigger += 1
            AppLogger.log("updated message: \(message.id), text length: \(existingMessage.text.count), FINAL state: \(existingMessage.state)", category: .nativeChat)
        } else {
            let similarIndex = vm.messages.firstIndex { existing in
                existing.role == message.role &&
                existing.text == message.text &&
                abs(existing.timestamp.timeIntervalSince(message.timestamp)) < 60.0
            }
            if let similarIndex = similarIndex {
                var existingMessage = vm.messages[similarIndex]
                AppLogger.log("receiveMessage similar-match - newId=\(String(message.id.prefix(8))) existingId=\(String(existingMessage.id.prefix(8))) idx=\(similarIndex) state=\(message.state)", category: .nativeChat)
                if !message.text.isEmpty {
                    existingMessage.text = message.text
                }
                existingMessage.state = message.state
                if message.startedAt != nil { existingMessage.startedAt = message.startedAt }
                if message.endedAt != nil { existingMessage.endedAt = message.endedAt }
                if message.livenessState != nil { existingMessage.livenessState = message.livenessState }
                if message.seq != nil { existingMessage.seq = message.seq }
                if message.inputTokens != nil { existingMessage.inputTokens = message.inputTokens }
                if message.outputTokens != nil { existingMessage.outputTokens = message.outputTokens }
                if message.cacheRead != nil { existingMessage.cacheRead = message.cacheRead }
                if message.cacheWrite != nil { existingMessage.cacheWrite = message.cacheWrite }
                vm.messages[similarIndex] = existingMessage
                vm.scrollTrigger += 1
            } else {
                if let last = vm.messages.last, last.state != "final" {
                    vm.messages.insert(message, at: vm.messages.count - 1)
                    AppLogger.log("receiveMessage new (inserted before last, lastState=\(last.state)) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                } else {
                    vm.messages.append(message)
                    AppLogger.log("receiveMessage new (appended) - id: \(String(message.id.prefix(8))), text len: \(message.text.count), state: \(message.state)", category: .nativeChat)
                }
                vm.scrollTrigger += 1
            }
        }
        if message.state == "final" {
            // Intentionally do NOT write the streaming copy to the
            // cache here. The agent-end event payload does not carry
            // usage tokens, so the streaming copy's dedup key
            // (`role|text|bucket|usage`) differs from the network's
            // server-stored message (which has the full usage).
            // Writing the streaming copy would cause both versions
            // to land in the cache — and on re-entry, both would
            // display, with the streaming copy missing the 4 token
            // values. loadHistory's network fetch is the
            // authoritative cache writer and runs on every entry.
            vm.isSending = false
        }
    }

    /// Append new messages from the transport without going through dedup.
    /// Used for bulk operations (not currently exercised by any caller
    /// in the production code path, but kept for parity with the VM's
    /// pre-refactor surface).
    func appendNewMessages(_ newMessages: [ChatMessage]) {
        guard let vm = viewModel else { return }
        if newMessages.isEmpty {
            AppLogger.log("appendNewMessages - no new messages", category: .nativeChat)
            return
        }
        AppLogger.log("appendNewMessages appending \(newMessages.count) messages", category: .nativeChat)
        vm.messages.append(contentsOf: newMessages)
        vm.needsScrollToBottom = true
    }
}
```

- [ ] **Step 2: Wire it up in the VM**

In `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`:

a) Add a property next to the state block (around line 32):

```swift
let messageReceiver: MessageReceiver
```

b) Initialize in `init()` (currently `init() {}` on line 46):

```swift
init() {
    self.messageReceiver = MessageReceiver()
    self.messageReceiver.viewModel = self
}
```

c) Replace the VM's `receiveMessage(_:)` method (lines 714-799) with a one-line forwarder:

```swift
func receiveMessage(_ message: ChatMessage) {
    messageReceiver.receiveMessage(message)
}
```

d) Delete the `appendNewMessages(_:)` method (lines 704-712).

- [ ] **Step 3: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 50 tests pass (44 original + 6 from Task 3).

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/NativeChat/Internal/MessageReceiver.swift \
        SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatApp.xcodeproj
git commit -m "refactor(nativechat): extract MessageReceiver collaborator from VM"
```

---

## Task 7: Extract `HistoryLoader` from `NativeChatViewModel`

**Files:**
- Create: `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift`
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (lines 422-651, 657-702)

- [ ] **Step 1: Create the `HistoryLoader` collaborator**

Create `SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift`:

```swift
import SwiftUI
import OpenClawChatUI

@MainActor
final class HistoryLoader {
    weak var viewModel: NativeChatViewModel?

    @ObservationIgnored
    private static let loadHistoryLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    func loadHistory() {
        guard let vm = viewModel, let session = vm.selectedSession else { return }
        let sessionKey = session.key
        let sessionKeyPreview = String(sessionKey.prefix(8))
        let isRestoring = vm.isRestoringFromCache
        vm.isRestoringFromCache = false

        let cachedSessionKey = sessionKey
        let cachedSessionKeyPreview = sessionKeyPreview
        let cachedIsRestoring = isRestoring

        let alreadyInProgress = Self.loadHistoryLock.withLock { state -> Bool in
            let isInProgress = state == cachedSessionKey
            if !isInProgress {
                state = cachedSessionKey
            }
            return isInProgress
        }
        if alreadyInProgress {
            AppLogger.log("[loadHistory] already in progress for \(cachedSessionKeyPreview)", category: .nativeChat)
        }

        let taskIdStr = String(UUID().uuidString.prefix(8))

        Task { [cachedSessionKey, cachedSessionKeyPreview, cachedIsRestoring, taskIdStr] in
            AppLogger.log("[\(taskIdStr)] loadHistory Task started, sessionKey: \(cachedSessionKeyPreview)", category: .nativeChat)
            defer {
                Self.loadHistoryLock.withLock { state in
                    if state == cachedSessionKey {
                        state = nil
                    }
                }
            }
            let cachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
            AppLogger.log("cache returned \(cachedMessages.count) messages, sessionKey: \(cachedSessionKeyPreview)", category: .nativeChat)
            if !cachedMessages.isEmpty {
                let chatMessages = cachedMessages.compactMap { msg in ChatMessageConverter.toChatMessage(from: msg) }
                AppLogger.log("Loaded \(chatMessages.count) cached messages for session: \(cachedSessionKeyPreview), isRestoring: \(cachedIsRestoring)", category: .nativeChat)
                await MainActor.run {
                    MarkdownCache.shared.precomputeForMessages(chatMessages)
                    CollapseStateCache.shared.precompute(for: chatMessages)
                }
                self.loadedCachedHistory(chatMessages, isRestoring: cachedIsRestoring)
            }

            do {
                try await SessionManager.shared.ensureConnected()
                let transport = await SessionManager.shared.makeTransport(sessionKey: cachedSessionKey)
                let history = try await transport.requestHistory(sessionKey: cachedSessionKey)

                let messageCount = history.messages?.count ?? 0
                AppLogger.log("Loaded \(messageCount) history messages for session: \(cachedSessionKeyPreview)", category: .nativeChat)
                let chatMessages: [ChatMessage] = (history.messages ?? []).enumerated().compactMap { index, anyCodable -> ChatMessage? in
                    guard let msg = try? JSONDecoder().decode(OpenClawChatMessage.self, from: JSONEncoder().encode(anyCodable)) else {
                        print("SMAlog: message[\(index)] failed to decode as OpenClawChatMessage, raw: \(String(describing: anyCodable))")
                        return nil
                    }
                    return ChatMessageConverter.toChatMessage(from: msg)
                }
                AppLogger.log("chatMessages count=\(chatMessages.count)", category: .nativeChat)
                let openClawMessages = chatMessages.compactMap { ChatMessageConverter.toOpenClawChatMessage(from: $0) }
                AppLogger.log("openClawMessages count=\(openClawMessages.count)", category: .nativeChat)
                await MessageCache.shared.setMessages(openClawMessages, for: cachedSessionKey)

                let finalCachedMessages = await MessageCache.shared.getMessages(for: cachedSessionKey)
                let finalChatMessages = finalCachedMessages.compactMap { msg in ChatMessageConverter.toChatMessage(from: msg) }
                AppLogger.log("[\(taskIdStr)] finalCachedMessages from cache: \(finalChatMessages.count)", category: .nativeChat)

                if cachedMessages.isEmpty {
                    self.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages)
                } else if finalChatMessages.count > cachedMessages.count {
                    self.loadedNetworkHistory(sessionKey: cachedSessionKey, messages: finalChatMessages)
                } else {
                    AppLogger.log("[\(taskIdStr)] Network returned same messages as cache, skipping UI update", category: .nativeChat)
                }
            } catch {
                AppLogger.log("Load history error: \(error.localizedDescription)", category: .nativeChat, level: .error)
            }
        }
    }

    private func loadedCachedHistory(_ messages: [ChatMessage], isRestoring: Bool) {
        guard let vm = viewModel else { return }
        AppLogger.log("loadedCachedHistory setting \(messages.count) messages, isRestoring: \(isRestoring)", category: .nativeChat)
        vm.messages = messages
        vm.scrollTrigger += 1
        vm.cacheLoadCounter += 1
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
            self.incrementCacheCounter()
        }
    }

    private func loadedNetworkHistory(sessionKey: String, messages: [ChatMessage]) {
        guard let vm = viewModel else { return }
        let currentKey = vm.selectedSession?.key
        if currentKey != sessionKey {
            let currentKeyLog = currentKey ?? "nil"
            AppLogger.log("loadedNetworkHistory dropped: session \(String(sessionKey.prefix(8))) is no longer selected (current: \(String(currentKeyLog.prefix(8))))", category: .nativeChat, level: .warning)
            return
        }
        AppLogger.log("loadedNetworkHistory applying \(messages.count) messages for session: \(String(sessionKey.prefix(8)))", category: .nativeChat)
        vm.messages = messages
        vm.scrollTrigger += 1
        vm.cacheLoadCounter += 1
        Task { [messages] in
            await MainActor.run {
                MarkdownCache.shared.precomputeForMessages(messages)
                CollapseStateCache.shared.precompute(for: messages)
            }
            self.incrementCacheCounter()
        }
    }

    private func incrementCacheCounter() {
        viewModel?.cacheLoadCounter += 1
    }
}
```

- [ ] **Step 2: Wire it up in the VM**

In `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`:

a) Add a property next to `messageReceiver` (added in Task 6):

```swift
let historyLoader: HistoryLoader
```

b) Update `init()`:

```swift
init() {
    self.messageReceiver = MessageReceiver()
    self.historyLoader = HistoryLoader()
    self.messageReceiver.viewModel = self
    self.historyLoader.viewModel = self
}
```

c) Replace the VM's `loadHistory()` method (lines 422-651) with:

```swift
func loadHistory() {
    historyLoader.loadHistory()
}
```

d) Delete the `loadedCachedHistory(_:isRestoring:)` method (lines 657-671).

e) Delete the `loadedNetworkHistory(sessionKey:messages:)` method (lines 673-698).

f) Delete the `incrementCacheCounter()` method (lines 700-702).

g) Delete the now-orphaned static `loadHistoryLock` (lines 43-44) — it's been moved to `HistoryLoader`.

- [ ] **Step 3: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 50 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/NativeChat/Internal/HistoryLoader.swift \
        SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatApp.xcodeproj
git commit -m "refactor(nativechat): extract HistoryLoader collaborator from VM"
```

---

## Task 8: Extract `EventInterpreter` from `NativeChatViewModel`

**Files:**
- Create: `SmartChatApp/Features/NativeChat/Internal/EventInterpreter.swift`
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (lines 832-1280)

- [ ] **Step 1: Create the `EventInterpreter` collaborator with SDK accessors replacing private extractors**

Create `SmartChatApp/Features/NativeChat/Internal/EventInterpreter.swift`:

```swift
import SwiftUI
import OpenClawChatUI
import OpenClawKit

@MainActor
final class EventInterpreter {
    weak var viewModel: NativeChatViewModel?

    func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
        switch event {
        case .agent(let payload):
            AppLogger.log("agent event - stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) ts=\(payload.ts ?? 0) data=\(EventInterpreter.summarizeData(payload.data))", category: .nativeChat)
            let runId = payload.runId
            let ts = payload.ts ?? 0
            let timestamp = Date(timeIntervalSince1970: Double(ts) / 1000)
            let data = payload.data
            let seq = payload.seq
            let phase = data["phase"]?.stringValue
            let startedAtMs = data["startedAt"]?.doubleValue ?? 0
            let endedAtMs = data["endedAt"]?.doubleValue ?? 0
            let livenessState = data["livenessState"]?.stringValue

            switch payload.stream {
            case "lifecycle":
                if phase == "start" {
                    AppLogger.log("agent lifecycle start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)", category: .nativeChat)
                    await MainActor.run {
                        MarkdownStreamManager.shared.holder(for: runId)
                        MarkdownCache.shared.setNeedsMarkdown(runId, value: true)
                    }
                    let message = ChatMessage(
                        id: runId,
                        text: "",
                        timestamp: timestamp,
                        role: "assistant",
                        state: "streaming",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp,
                        endedAt: nil,
                        livenessState: livenessState,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                } else if phase == "end" {
                    AppLogger.log("agent lifecycle end - runId: \(runId), data keys: \(data.keys.map { $0 })", category: .nativeChat)
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var cacheRead: Int?
                    var cacheWrite: Int?
                    if let usage = data["usage"]?.value as? [String: Any] {
                        AppLogger.log("found usage dict: \(String(describing: usage))", category: .nativeChat)
                        if let input = usage["input"] as? Int { inputTokens = input }
                        if let output = usage["output"] as? Int { outputTokens = output }
                        if let cr = usage["cacheRead"] as? Int { cacheRead = cr }
                        if let cw = usage["cacheWrite"] as? Int { cacheWrite = cw }
                    }
                    if inputTokens == nil, let input = data["inputTokens"]?.intValue { inputTokens = input }
                    if outputTokens == nil, let output = data["outputTokens"]?.intValue { outputTokens = output }
                    if cacheRead == nil, let cr = data["cacheRead"]?.intValue { cacheRead = cr }
                    if cacheWrite == nil, let cw = data["cacheWrite"]?.intValue { cacheWrite = cw }
                    AppLogger.log("agent lifecycle end - tokens: input: \(inputTokens ?? -1), output: \(outputTokens ?? -1), cacheRead: \(cacheRead ?? -1), cacheWrite: \(cacheWrite ?? -1)", category: .nativeChat)
                    let fullText: String = await MainActor.run {
                        MarkdownStreamManager.shared.end(messageId: runId)
                        return MarkdownStreamManager.shared.currentText(for: runId) ?? ""
                    }
                    AppLogger.log("agent lifecycle end - fullText len: \(fullText.count) for runId: \(runId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: runId,
                        text: fullText,
                        timestamp: timestamp,
                        role: "assistant",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                        endedAt: endedAtMs > 0 ? Date(timeIntervalSince1970: endedAtMs / 1000) : timestamp,
                        livenessState: livenessState,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                    await MainActor.run {
                        MarkdownStreamManager.shared.release(messageId: runId)
                    }
                    viewModel?.isSending = false
                }
            case "assistant":
                let text = data["text"]?.stringValue ?? ""
                AppLogger.log("agent assistant delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    MarkdownStreamManager.shared.appendCumulative(messageId: runId, cumulative: text)
                }
                let message = ChatMessage(
                    id: runId,
                    text: text,
                    timestamp: timestamp,
                    role: "assistant",
                    state: "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            case "thinking":
                let text = data["text"]?.stringValue ?? ""
                AppLogger.log("agent thinking delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                let message = ChatMessage(
                    id: "\(runId):thinking",
                    text: text,
                    timestamp: timestamp,
                    role: "thinking",
                    state: "final",
                    runId: runId,
                    seq: nil,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            case "tool":
                guard let toolCallId = data["toolCallId"]?.stringValue else {
                    AppLogger.log("agent tool event missing toolCallId, skipping. data keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let toolName = data["name"]?.stringValue ?? ""
                if phase == "start" {
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool start - tool: \(toolName), callId: \(toolCallId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: timestamp,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                } else if phase == "update" {
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool update - tool: \(toolName), callId: \(toolCallId), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = MessageFormatters.formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    AppLogger.log("agent tool result - tool: \(toolName), callId: \(toolCallId), isError: \(isError), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolResult",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                        endedAt: timestamp,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: isError ? "error" : nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                }
            case "item":
                guard let itemId = data["itemId"]?.stringValue else {
                    AppLogger.log("agent item event missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let itemPhase = data["phase"]?.stringValue
                let kind = data["kind"]?.stringValue ?? "tool"
                let name = data["name"]?.stringValue ?? ""
                let status = data["status"]?.stringValue
                let progressText = data["progressText"]?.stringValue
                let summary = data["summary"]?.stringValue
                let errorText = data["error"]?.stringValue
                let toolCallId = data["toolCallId"]?.stringValue
                let meta = data["meta"]?.stringValue
                AppLogger.log("agent item - kind: \(kind), phase: \(itemPhase ?? "nil"), itemId: \(itemId), status: \(status ?? "?")", category: .nativeChat)
                var callText = MessageFormatters.formatToolCallBubbleText(name: name, arguments: data["args"], meta: meta)
                if callText.isEmpty {
                    callText = "ToolCall: \(kind)"
                }
                if let progressText, !progressText.isEmpty {
                    callText += "\n" + progressText
                }
                if itemPhase == "end" {
                    let resultText = summary ?? errorText ?? ""
                    if !resultText.isEmpty {
                        let message = ChatMessage(
                            id: "\(runId):itemResult:\(itemId)",
                            text: resultText,
                            timestamp: timestamp,
                            role: "toolResult",
                            state: "final",
                            runId: runId,
                            seq: seq,
                            startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                            endedAt: timestamp,
                            livenessState: nil,
                            toolCallId: toolCallId,
                            toolName: name,
                            stopReason: (errorText != nil) ? "error" : nil,
                            isFresh: true
                        )
                        viewModel?.receiveMessage(message)
                    }
                }
                let message = ChatMessage(
                    id: "\(runId):item:\(itemId)",
                    text: callText,
                    timestamp: timestamp,
                    role: "toolCall",
                    state: itemPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: itemPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: toolCallId,
                    toolName: name,
                    stopReason: nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            case "command_output":
                guard let itemId = data["itemId"]?.stringValue else {
                    AppLogger.log("agent command_output missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let outputPhase = data["phase"]?.stringValue
                let output = data["output"]?.stringValue ?? ""
                let toolName = data["name"]?.stringValue ?? ""
                let exitCode = data["exitCode"]?.intValue
                let durationMs = data["durationMs"]?.intValue
                AppLogger.log("agent command_output - phase: \(outputPhase ?? "nil"), itemId: \(itemId), output len: \(output.count), exitCode: \(exitCode.map(String.init) ?? "nil")", category: .nativeChat)
                var resultText = output
                if outputPhase == "end" {
                    var trailer: [String] = []
                    if let exitCode { trailer.append("exit=\(exitCode)") }
                    if let durationMs { trailer.append("duration=\(durationMs)ms") }
                    if !trailer.isEmpty {
                        if !resultText.isEmpty { resultText += "\n" }
                        resultText += trailer.joined(separator: " ")
                    }
                }
                guard !resultText.isEmpty else { return }
                let message = ChatMessage(
                    id: "\(runId):itemResult:\(itemId)",
                    text: resultText,
                    timestamp: timestamp,
                    role: "toolResult",
                    state: outputPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: outputPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: toolName,
                    stopReason: exitCode.map { $0 != 0 ? "error" : nil } ?? nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            default:
                AppLogger.log("agent UNHANDLED stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) data=\(EventInterpreter.summarizeData(data))", category: .nativeChat)
            }

        case .chat(let chat):
            var role = "?"
            var blockSummaries: [String] = []
            if let msgAny = chat.message?.value {
                let unwrapped = EventInterpreter.unwrapAnyCodable(msgAny)
                if let dict = unwrapped as? [String: Any] {
                    role = (dict["role"] as? String) ?? "?"
                    if let content = dict["content"] as? [Any] {
                        for (i, block) in content.enumerated() {
                            if let blockDict = block as? [String: Any] {
                                var parts: [String] = ["#\(i)"]
                                if let type = blockDict["type"] as? String { parts.append("type=\(type)") }
                                if let t = blockDict["text"] as? String, !t.isEmpty {
                                    let preview = t.prefix(80)
                                    parts.append("text=\"\(preview)\(t.count > 80 ? "…(\(t.count))" : "")\"")
                                }
                                if let th = blockDict["thinking"] as? String, !th.isEmpty {
                                    let preview = th.prefix(80)
                                    parts.append("thinking=\"\(preview)\(th.count > 80 ? "…(\(th.count))" : "")\"")
                                }
                                if let n = blockDict["name"] as? String { parts.append("name=\(n)") }
                                if let id = blockDict["id"] as? String { parts.append("id=\(id)") }
                                blockSummaries.append(parts.joined(separator: " "))
                            } else {
                                blockSummaries.append("#\(i)=<\(type(of: block))>")
                            }
                        }
                    } else if let content = dict["content"] {
                        blockSummaries = ["content=\(EventInterpreter.formatValue(content))"]
                    }
                } else if let str = unwrapped as? String {
                    blockSummaries = ["string=\"\(str.prefix(100))\""]
                }
            }
            AppLogger.log("chat event runId=\(chat.runId ?? "nil") sessionKey=\(chat.sessionKey ?? "nil") state=\(chat.state ?? "nil") role=\(role) blocks=[\(blockSummaries.joined(separator: " | "))] errorMessage=\(chat.errorMessage ?? "nil")", category: .nativeChat)

        case .sessionMessage(let sm):
            var blockSummaries: [String] = []
            if let blocks = sm.message?.content {
                for (i, block) in blocks.enumerated() {
                    var parts: [String] = ["#\(i)", "type=\(block.type ?? "?")"]
                    if let t = block.text, !t.isEmpty { parts.append("text=\"\(t.prefix(80))\(t.count > 80 ? "…" : "")\"") }
                    if let th = block.thinking, !th.isEmpty { parts.append("thinking=\"\(th.prefix(80))\(th.count > 80 ? "…" : "")\"") }
                    if let n = block.name { parts.append("name=\(n)") }
                    if let id = block.id { parts.append("id=\(id)") }
                    blockSummaries.append(parts.joined(separator: " "))
                }
            }
            AppLogger.log("sessionMessage messageId=\(sm.messageId ?? "nil") messageSeq=\(sm.messageSeq ?? -1) role=\(sm.message?.role ?? "nil") blocks=[\(blockSummaries.joined(separator: " | "))]", category: .nativeChat)

        case .tick:
            AppLogger.log("transport tick", category: .nativeChat)
        case .seqGap:
            AppLogger.log("transport seqGap (out-of-order event detected)", category: .nativeChat)
        case .health(let ok):
            AppLogger.log("transport health ok=\(ok)", category: .nativeChat)
        }
    }

    // MARK: - Static helpers (kept here because they're only used in `.log(...)` paths)

    private static func summarizeData(_ data: [String: AnyCodable]) -> String {
        let parts = data.keys.sorted().map { key -> String in
            guard let v = data[key]?.value else { return "\(key)=null" }
            return "\(key)=\(EventInterpreter.formatValue(v))"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    private static func formatValue(_ v: Any) -> String {
        if let s = v as? String {
            let preview = s.prefix(120)
            return "\"\(preview)\(s.count > 120 ? "…(\(s.count))" : "")\""
        }
        if let b = v as? Bool { return "\(b)" }
        if let i = v as? Int { return "\(i)" }
        if let d = v as? Double { return "\(d)" }
        if let arr = v as? [Any] { return "[\(arr.count) items]" }
        if let dict = v as? [String: Any] { return "{\(dict.count) keys:\(dict.keys.sorted().prefix(8).joined(separator: ","))}" }
        if v is NSNull { return "null" }
        return "<\(type(of: v))>"
    }

    private static func unwrapAnyCodable(_ v: Any) -> Any {
        if let ac = v as? AnyCodable { return EventInterpreter.unwrapAnyCodable(ac.value) }
        if let arr = v as? [Any] { return arr.map { EventInterpreter.unwrapAnyCodable($0) } }
        if let arr = v as? [AnyCodable] { return arr.map { EventInterpreter.unwrapAnyCodable($0) } }
        if let dict = v as? [String: Any] { return dict.mapValues { EventInterpreter.unwrapAnyCodable($0) } }
        if let dict = v as? [String: AnyCodable] { return dict.mapValues { EventInterpreter.unwrapAnyCodable($0) } }
        return v
    }
}
```

> **Note for the implementer:** `EventInterpreter` is the **only** file in the refactored code that calls SDK's `AnyCodable.stringValue` / `intValue` / `doubleValue` accessors. The other three collaborators (`SessionCoordinator`, `HistoryLoader`, `MessageReceiver`) consume already-decoded Swift values — they never touch `AnyCodable` directly. This concentration is deliberate: if we ever want to drop the `AnyCodable+Helpers` dependency (e.g., to vendor the SDK or switch to a different JSON lib), the migration is a single-file edit. The `summarizeData` / `formatValue` / `unwrapAnyCodable` helpers kept as `private static` here are for `.log(...)` argument formatting only — they're logging-only, not data extraction, so they don't fit `AnyCodable+Helpers`'s purpose and stay in this file.

- [ ] **Step 2: Wire it up in the VM**

In `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`:

a) Add a property next to `historyLoader`:

```swift
let eventInterpreter: EventInterpreter
```

b) Update `init()`:

```swift
init() {
    self.messageReceiver = MessageReceiver()
    self.historyLoader = HistoryLoader()
    self.eventInterpreter = EventInterpreter()
    self.messageReceiver.viewModel = self
    self.historyLoader.viewModel = self
    self.eventInterpreter.viewModel = self
}
```

c) Replace the VM's `handleTransportEvent(_:sessionKey:)` method (lines 832-1280) with:

```swift
func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
    await eventInterpreter.handleTransportEvent(event, sessionKey: sessionKey)
}
```

d) Delete the private `extractString/Double/Int`, `summarizeData`, `formatValue`, `summarizeAny`, `unwrapAnyCodable` methods (lines 1313-1386). They've been replaced by SDK `AnyCodable+Helpers` accessors in EventInterpreter.

- [ ] **Step 3: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 50 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/NativeChat/Internal/EventInterpreter.swift \
        SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatApp.xcodeproj
git commit -m "refactor(nativechat): extract EventInterpreter collaborator from VM"
```

---

## Task 9: Extract `SessionCoordinator` from `NativeChatViewModel`

**Files:**
- Create: `SmartChatApp/Features/NativeChat/Internal/SessionCoordinator.swift`
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (lines 6-8, 56-353)

- [ ] **Step 1: Create the `SessionCoordinator` collaborator**

Create `SmartChatApp/Features/NativeChat/Internal/SessionCoordinator.swift`:

```swift
import SwiftUI
import OpenClawChatUI

@MainActor
final class SessionCoordinator {
    weak var viewModel: NativeChatViewModel?

    private func lastSelectedSessionKey(for profileId: UUID) -> String {
        "lastSelectedSession_\(profileId.uuidString)"
    }

    func loadSessions() {
        guard let vm = viewModel else { return }
        AppLogger.log("loadSessions called", category: .nativeChat)
        guard let profileId = vm.selectedProfileId else {
            AppLogger.log("loadSessions skipped - no selected profile", category: .nativeChat, level: .warning)
            return
        }
        let profileIdCapture = profileId
        if let cached = SessionCache.load(for: profileId), !cached.isEmpty {
            AppLogger.log("Loaded \(cached.count) cached sessions for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
            vm.sessions = cached
            vm.isRestoringFromCache = true

            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileIdCapture))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                vm.selectedSession = lastSession
                AppLogger.log("restored last selected session: \(String(lastSession.key.prefix(12)))", category: .nativeChat)
            } else if vm.selectedSession == nil, let first = cached.first {
                vm.selectedSession = first
                AppLogger.log("Auto-selected first session: \(String(first.key.prefix(12)))", category: .nativeChat)
            }
            vm.isRestoringFromCache = false
        } else {
            AppLogger.log("No cached sessions found for profile \(profileIdCapture.uuidString.prefix(8))", category: .nativeChat)
        }
        vm.isLoading = true
        vm.error = nil
        vm.loadHistory()
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                try await Task.sleep(for: .milliseconds(100))
                let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                let response = try await transport.listSessions(limit: 50)
                AppLogger.log("Loaded \(response.sessions.count) sessions", category: .nativeChat)
                self.loadedSessions(response.sessions)
            } catch {
                AppLogger.log("Load sessions error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                try? await Task.sleep(for: .milliseconds(500))
                do {
                    try await SessionManager.shared.ensureConnected()
                    let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                    let response = try await transport.listSessions(limit: 50)
                    self.loadedSessions(response.sessions)
                } catch {
                    AppLogger.log("Load sessions retry failed: \(error.localizedDescription)", category: .nativeChat, level: .error)
                    self.loadedSessions([])
                }
            }
        }
    }

    func loadedSessions(_ sessions: [OpenClawChatSessionEntry]) {
        guard let vm = viewModel else { return }
        let prevSelectedKey = vm.selectedSession?.key
        let prevSelectedModel = vm.selectedSession?.model
        let prevSelectedTokens = vm.selectedSession?.totalTokens
        let prevSelectedUpdatedAt = vm.selectedSession?.updatedAt
        AppLogger.log("[loadedSessions DIAG] prev selected: key=\(String(prevSelectedKey?.prefix(12) ?? "nil")) model=\(prevSelectedModel ?? "nil") tokens=\(prevSelectedTokens ?? -1) updatedAt=\(prevSelectedUpdatedAt ?? -1)", category: .nativeChat)
        AppLogger.log("[loadedSessions DIAG] incoming: count=\(sessions.count) first.model=\(sessions.first?.model ?? "nil") first.tokens=\(sessions.first?.totalTokens ?? -1) first.updatedAt=\(sessions.first?.updatedAt ?? -1)", category: .nativeChat)

        vm.sessions = sessions
        vm.isLoading = false
        if let profileId = vm.selectedProfileId {
            SessionCache.save(sessions, for: profileId)
        }

        if let profileId = vm.selectedProfileId,
           let key = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: profileId)),
           let updatedSession = sessions.first(where: { $0.key == key }) {
            vm.selectedSession = updatedSession
            let sameKey = updatedSession.key == prevSelectedKey
            let sameModel = updatedSession.model == prevSelectedModel
            let sameTokens = updatedSession.totalTokens == prevSelectedTokens
            let sameUpdatedAt = updatedSession.updatedAt == prevSelectedUpdatedAt
            AppLogger.log("[loadedSessions DIAG] branch=lastKeyMatch key=\(String(updatedSession.key.prefix(12))) newModel=\(updatedSession.model ?? "nil") newTokens=\(updatedSession.totalTokens ?? -1) newUpdatedAt=\(updatedSession.updatedAt ?? -1) sameKey=\(sameKey ? 1 : 0) sameModel=\(sameModel ? 1 : 0) sameTokens=\(sameTokens ? 1 : 0) sameUpdatedAt=\(sameUpdatedAt ? 1 : 0)", category: .nativeChat)
            vm.loadHistory()
            return
        }

        if vm.selectedSession == nil, let first = sessions.first {
            vm.selectedSession = first
            AppLogger.log("[loadedSessions DIAG] branch=autoFirst key=\(String(first.key.prefix(12)))", category: .nativeChat)
            vm.loadHistory()
            return
        }
        if let currentKey = prevSelectedKey,
           let refreshed = sessions.first(where: { $0.key == currentKey }) {
            vm.selectedSession = refreshed
            AppLogger.log("[loadedSessions DIAG] branch=inPlaceRefresh key=\(String(currentKey.prefix(12))) newModel=\(refreshed.model ?? "nil") newTokens=\(refreshed.totalTokens ?? -1) newUpdatedAt=\(refreshed.updatedAt ?? -1)", category: .nativeChat)
        } else {
            AppLogger.log("[loadedSessions DIAG] branch=noMatch prevKey=\(String(prevSelectedKey?.prefix(12) ?? "nil")) sessionsCount=\(sessions.count)", category: .nativeChat)
        }
    }

    func selectSession(_ session: OpenClawChatSessionEntry) {
        guard let vm = viewModel else { return }
        let previousKey = vm.selectedSession?.key
        if let fresh = vm.sessions.first(where: { $0.key == session.key }) {
            vm.selectedSession = fresh
        } else {
            vm.selectedSession = session
        }

        let didSwitch = previousKey != session.key
        if didSwitch {
            vm.messages = []
            vm.isRestoringFromCache = true
        }

        if let profileId = vm.selectedProfileId {
            UserDefaults.standard.set(session.key, forKey: lastSelectedSessionKey(for: profileId))
        }
        AppLogger.log("saved selected session: \(String(session.key.prefix(12)))", category: .nativeChat)
        if didSwitch {
            Task { @MainActor in
                MarkdownStreamManager.shared.releaseAll()
            }
            vm.loadSessions()
            vm.loadHistory()
        } else {
            vm.loadHistory()
        }
    }

    func switchProfile(_ newProfileId: UUID) {
        guard let vm = viewModel else { return }
        if newProfileId == vm.selectedProfileId {
            return
        }
        let previousProfileId = vm.selectedProfileId
        vm.selectedProfileId = newProfileId
        vm.selectedSession = nil
        vm.messages = []
        vm.isSwitchingGateway = true
        vm.error = nil
        AppLogger.log("switchProfile from \(previousProfileId?.uuidString.prefix(8) ?? "nil") to \(newProfileId.uuidString.prefix(8))", category: .nativeChat)

        var hasCache = false
        if let cached = SessionCache.load(for: newProfileId), !cached.isEmpty {
            vm.sessions = cached
            vm.isRestoringFromCache = true
            let lastKey = UserDefaults.standard.string(forKey: lastSelectedSessionKey(for: newProfileId))
            if let key = lastKey, let lastSession = cached.first(where: { $0.key == key }) {
                vm.selectedSession = lastSession
            } else if let first = cached.first {
                vm.selectedSession = first
            }
            vm.isRestoringFromCache = false
            hasCache = true
        } else {
            vm.sessions = []
            vm.isRestoringFromCache = false
            vm.isLoading = true
        }

        let profileIdCapture = newProfileId
        let hadCache = hasCache
        Task {
            await MainActor.run {
                MarkdownStreamManager.shared.releaseAll()
            }
            if hadCache {
                vm.loadHistory()
            }

            let profile = await MainActor.run {
                ProfileManager.shared.getProfile(id: profileIdCapture)
            }
            guard let profile = profile else {
                AppLogger.log("switchProfile - profile not found", category: .nativeChat, level: .warning)
                vm.error = "Profile not found"
                return
            }
            await ProfileManager.shared.switchToProfile(profile)
            AppLogger.log("switchProfile - active profile switched, fetching network sessions", category: .nativeChat)

            do {
                try await SessionManager.shared.ensureConnected()
                try await Task.sleep(for: .milliseconds(100))
                let transport = await SessionManager.shared.makeTransport(sessionKey: "")
                let response = try await transport.listSessions(limit: 50)
                self.loadedSessions(response.sessions)
            } catch {
                AppLogger.log("Load sessions after switch error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                vm.error = error.localizedDescription
            }
            vm.isSwitchingGateway = false
            vm.isLoading = false
        }
    }

    func createSession() {
        guard let vm = viewModel else { return }
        vm.isLoading = true
        let selectedAgentId: String? = {
            guard let key = vm.selectedSession?.key else { return nil }
            return SessionKey.parse(key).agentId
        }()
        AppLogger.log("createSession - using selected agentId: \(selectedAgentId ?? "<default>")", category: .nativeChat)

        let customKey: String? = {
            guard let agent = selectedAgentId, !agent.isEmpty else { return nil }
            let clientLabel = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
                ?? "SmartChatApp"
            return SessionKey.makeNew(agentId: agent, clientLabel: clientLabel)
        }()
        if let customKey {
            AppLogger.log("createSession - requesting custom key: \(customKey)", category: .nativeChat)
        }

        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let sessionKey = try await SessionManager.shared.createSession(
                    agentId: selectedAgentId,
                    customKey: customKey
                )
                AppLogger.log("Created session: \(String(sessionKey))", category: .nativeChat)
                self.sessionCreated(sessionKey)
                vm.loadSessions()
            } catch {
                AppLogger.log("Create session error: \(error.localizedDescription)", category: .nativeChat, level: .error)
                vm.error = error.localizedDescription
            }
        }
    }

    func sessionCreated(_ sessionKey: String) {
        guard let vm = viewModel else { return }
        AppLogger.log("Session created callback: \(sessionKey)", category: .nativeChat)
        vm.isLoading = false
        let newEntry = OpenClawChatSessionEntry(
            key: sessionKey,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil
        )
        vm.selectSession(newEntry)
    }
}
```

- [ ] **Step 2: Wire it up in the VM**

In `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift`:

a) Add a property:

```swift
let sessionCoordinator: SessionCoordinator
```

b) Update `init()`:

```swift
init() {
    self.messageReceiver = MessageReceiver()
    self.historyLoader = HistoryLoader()
    self.eventInterpreter = EventInterpreter()
    self.sessionCoordinator = SessionCoordinator()
    self.messageReceiver.viewModel = self
    self.historyLoader.viewModel = self
    self.eventInterpreter.viewModel = self
    self.sessionCoordinator.viewModel = self
}
```

c) Replace these VM methods with one-line forwarders:

```swift
func loadSessions() { sessionCoordinator.loadSessions() }
func loadedSessions(_ sessions: [OpenClawChatSessionEntry]) { sessionCoordinator.loadedSessions(sessions) }
func selectSession(_ session: OpenClawChatSessionEntry) { sessionCoordinator.selectSession(session) }
func switchProfile(_ newProfileId: UUID) { sessionCoordinator.switchProfile(newProfileId) }
func createSession() { sessionCoordinator.createSession() }
func sessionCreated(_ sessionKey: String) { sessionCoordinator.sessionCreated(sessionKey) }
```

d) Delete the bodies of the old `loadSessions` (line 56–112), `loadedSessions` (line 114–161), `selectSession` (line 163–197), `switchProfile` (line 199–268), `createSession` (line 270–322), `sessionCreated` (line 324–353). They've been replaced by the forwarders above.

e) Delete the file-scope `lastSelectedSessionKey(for:)` function (lines 6–8). It's now a private method on `SessionCoordinator`.

f) Delete the VM's `setError(_:)` and `setSending(_:)` methods (lines 801-809) — they were only used by old session/history logic. The new collaborators write to `vm.error` / `vm.isSending` directly.

g) Delete the VM's `finishSwitchingGateway()` method (lines 827-830) — its body is now inlined in `SessionCoordinator.switchProfile`.

- [ ] **Step 3: Build, verify it compiles**

```bash
make build
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 50 tests pass.

- [ ] **Step 5: Verify VM is now under 300 lines**

```bash
wc -l SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
```

Expected: between 250 and 300 lines.

- [ ] **Step 6: Commit**

```bash
git add SmartChatApp/Features/NativeChat/Internal/SessionCoordinator.swift \
        SmartChatApp/Features/NativeChat/NativeChatViewModel.swift \
        SmartChatApp.xcodeproj
git commit -m "refactor(nativechat): extract SessionCoordinator collaborator from VM"
```

---

## Task 10: Final verification + manual smoke test

**Files:** None (read-only checks + simulator install)

- [ ] **Step 1: Confirm VM line count is under 300**

```bash
wc -l SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
```

Expected: `<300` lines.

- [ ] **Step 2: Confirm all 4 collaborators exist**

```bash
ls -la SmartChatApp/Features/NativeChat/Internal/
```

Expected output: 4 files (`MessageReceiver.swift`, `HistoryLoader.swift`, `EventInterpreter.swift`, `SessionCoordinator.swift`), each <450 lines.

- [ ] **Step 3: Confirm Models/ is populated and Cards/ is view-only**

```bash
ls SmartChatApp/Models/
ls SmartChatApp/Cards/
```

Expected:
- `Models/`: `CardData.swift`, `GatewayProfile.swift`, `SessionKey.swift`
- `Cards/`: 4 view files + `ChatCardOverlay.swift` (no `CardModels.swift`)

- [ ] **Step 4: Confirm Core/Utilities/ exists**

```bash
ls SmartChatApp/Core/Utilities/
```

Expected: `MessageFormatters.swift`, `ChatMessageConverter.swift`

- [ ] **Step 5: Run all unit tests**

```bash
xcodebuild -project SmartChatApp.xcodeproj -scheme SmartChatAppTests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Expected: all 50 tests pass (22 formatter + 5 SessionKey + 6 ChatMessageConverter + 17 others).

- [ ] **Step 6: Build and install to iPhone**

```bash
make install
```

Expected: app builds and installs to the connected iPhone.

- [ ] **Step 7: Manual smoke test on the iPhone**

Launch the app and verify each of the following works without regression:

1. Open Settings — confirm all 4 gateway profiles appear.
2. Tap into NativeChat — confirm cached sessions appear, then network refresh updates model/tokens.
3. Send a message — confirm:
   - User message appears.
   - Assistant text streams in (typing indicator → markdown bubble).
   - On lifecycle end: `isSending = false`, input re-enables.
4. Trigger a tool call (e.g., ask the agent to read a file) — confirm:
   - `toolCall` bubble shows `ToolCall: <name>` + args lines (format preserved).
   - `toolResult` bubble shows pretty JSON or `exit=N duration=Mms` trailer.
5. Switch sessions — confirm messages reload from cache, then network refreshes.
6. Switch gateway profiles — confirm sessions switch, transport reconnects.
7. Open Settings → Debug Logs — confirm `[DIAG]` / `agent event -` / `tool result` log lines are unchanged.

- [ ] **Step 8: Compare VM line count vs. baseline**

```bash
echo "Baseline: 1525 lines"
wc -l SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
```

Expected: VM is now <300 lines (a ~80% reduction). The four collaborators together total ~1100 lines, but each is <450 and has one responsibility.

- [ ] **Step 9: Commit the verification marker (no code change)**

If all steps passed, no commit needed. If any manual fix was required, commit it with:

```bash
git add <touched files>
git commit -m "fix(nativechat): post-refactor smoke-test adjustments"
```

---

## Self-Review

### Spec Coverage

The plan implements the 5-point user request:
- **Point 1 (split NativeChat VM)**: Tasks 6–9 each extract one collaborator, plus Task 9 deletes the old bodies. Task 10 confirms <300 lines.
- **Point 1 (NativeChat folder relevance)**: All files in `Features/NativeChat/` are now either the VM (state), 4 collaborators (responsibility split), or views. No unrelated files.
- **Point 2 (Models folder populated)**: Task 1 adds `SessionKey.swift`; Task 4 moves `CardData.swift` in.
- **Point 3 (extract common functionality)**: Tasks 2 + 3 create `MessageFormatters` and `ChatMessageConverter`; `SessionKey` dedupes 4 inline parsers.
- **Point 4 (architecture optimization)**: MVVM layering is preserved; ViewModel becomes thin coordinator.
- **Point 5 (no functional change)**: Formatter tests (22) prove `MessageFormatters` is byte-equivalent. Manual smoke test (Task 10 step 7) verifies user-visible behavior is unchanged.

### Placeholder Scan

No "TBD", "TODO", "implement later", or "etc." in the plan. Every code block is complete and runnable. Every command has expected output.

### Type Consistency

- `SessionKey.parse(raw:) -> SessionKey` and `SessionKey.makeNew(agentId:clientLabel:) -> String` defined in Task 1, consumed in Tasks 5, 9. ✓
- `MessageFormatters.format*` defined in Task 2, consumed in Tasks 3, 7, 8, 9. ✓
- `ChatMessageConverter.toChatMessage(from:) -> ChatMessage?` and `toOpenClawChatMessage(from:) -> OpenClawChatMessage?` defined in Task 3, consumed in Task 7. ✓
- `weak var viewModel: NativeChatViewModel?` on all 4 collaborators, set in VM's `init()`. ✓
- All `OpenClawChatMessage` field accesses (`data["key"]?.stringValue`) match the SDK's `AnyCodable+Helpers` public API. ✓
- The `OSAllocatedUnfairLock<String?>` pattern in `HistoryLoader` matches the one in pre-refactor VM (lines 43–44 of the original). ✓

---

## Critical Files (Quick Reference)

| Path | Action | Result |
|---|---|---|
| `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` | Shrink | 1525 → ~280 lines |
| `SmartChatApp/Features/NativeChat/Internal/` | Create folder | 4 new files |
| `SmartChatApp/Core/Utilities/` | Create folder | 2 new files |
| `SmartChatApp/Models/SessionKey.swift` | Create | new value type |
| `SmartChatApp/Models/CardData.swift` | Move | from `Cards/CardModels.swift` |
| `SmartChatApp/Cards/CardModels.swift` | Delete | moved |
| `SmartChatApp/Features/NativeChat/SessionPickerView.swift` | Refactor | use `SessionKey.parse` |
| `SmartChatAppTests/NativeChatViewModelFormatterTests.swift` | Update | `sut.foo` → `MessageFormatters.foo` |
| `SmartChatAppTests/SessionKeyTests.swift` | Create | new unit tests |
| `SmartChatAppTests/ChatMessageConverterTests.swift` | Create | new unit tests |
| `SmartChatApp/Features/NativeChat/NativeChatView.swift` | **Unchanged** | public API preserved |
| `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` | **Unchanged** | |
| `SmartChatApp/Features/NativeChat/ChatInputView.swift` | **Unchanged** | |
| `SmartChatApp/Features/NativeChat/SessionTabBar.swift` | **Unchanged** | |
| `SmartChatApp/Core/Services/CardRegistry.swift` | **Unchanged** | same module, no import needed |
| `SmartChatApp/Cards/{Music,Video,Button,Image}CardView.swift` | **Unchanged** | same module, no import needed |

## Reused Existing Code

- **`AnyCodable.stringValue / intValue / doubleValue / boolValue / arrayValue / dictionaryValue / foundationValue`** — `openclaw/apps/shared/OpenClawKit/Sources/OpenClawKit/AnyCodable+Helpers.swift` (public extension). Used inside `EventInterpreter` (Task 8) to replace 4 private extractors + `unwrapAnyCodable`.
- **`OSAllocatedUnfairLock<String?>`** — pattern from pre-refactor VM lines 43–44, preserved in `HistoryLoader` (Task 7).
- **`ChatMessage` / `OpenClawChatMessage` / `OpenClawChatMessageContent` / `OpenClawChatUsage`** — from `OpenClawChatUI/ChatModels.swift` (no changes; just consumed).
- **`MessageFormatters.formatToolCallBubbleText` / `formatToolResultText`** — moved from VM (Task 2), consumed by `ChatMessageConverter.toChatMessage` (Task 3) and `EventInterpreter` (Task 8) and `SessionCoordinator.createSession` history path (Task 9).

## SDK Dependency Analysis & Future Compatibility

This section answers two forward-looking questions so future maintainers (or a future-us) don't have to redo the analysis: **(1) if the SDK becomes unsuitable, can we vendor our dependencies out of it?** and **(2) what unused SDK capabilities could inform future feature work?**

### Q1 — Migration Path: How to Drop the SDK

After this refactor, the SDK import surface in the refactored code is **7 types** plus 1 extension, all listed below. Of these, **5 are wire-format data types** (the protocol), and **2 are value-extraction helpers** (replaceable in 1 line each).

| SDK type / API | Used in (post-refactor) | Replace-with-app-code effort | Notes |
|---|---|---|---|
| `OpenClawChatMessage` | `ChatMessageConverter`, `HistoryLoader` | **Vendor it** (copy `OpenClawChatUI/ChatModels.swift` lines 138–214) | Wire format; can't be replaced, only vendored |
| `OpenClawChatMessageContent` | `ChatMessageConverter` | **Vendor it** (same file, lines 65–136) | Wire format |
| `OpenClawChatUsage` | `ChatMessageConverter` | **Vendor it** (same file, lines 24–63) | Wire format |
| `OpenClawChatSessionEntry` | `SessionCoordinator` | **Vendor it** (find in `OpenClawChatUI/ChatSessions.swift`) | Wire format |
| `OpenClawChatTransportEvent` (enum with 4 cases) | `EventInterpreter` | **Vendor it** (find in `OpenClawChatUI/ChatTransport.swift`) | Wire format |
| `ChatMessage` | All 4 collaborators + `ChatMessageConverter` | **Vendor it** (find in `OpenClawChatUI/ChatModels.swift`) | App-level message type; could even rename to drop `OpenClaw` prefix |
| `AnyCodable` + `stringValue / intValue / doubleValue` accessors | `EventInterpreter` | **Inline**: `data["key"]?.value as? String` etc., 4 lines | Trivial; this is why the refactor uses SDK accessors in only one file (`EventInterpreter`) |
| `OpenClawProtocol` module imports | `ChatMessageConverter` | The above vendored types may live in this module; re-export or move to app target | The OpenClawProtocol/OpenClawChatUI/OpenClawKit module split is itself a vendor concern |

**Total migration work: 1–2 days mechanical** — copy ~5 type files into the app target, rename imports, and inline 4 `as?` checks. The refactor reduces this from a hypothetical 1-week job (had the conversion logic stayed inlined 3× in `loadHistory` and the accessors stayed as 4 private methods on the VM) to 1–2 days because:

1. **`ChatMessageConverter` is the single wire-format ↔ app-message bridge.** Vendoring `OpenClawChatMessage` etc. requires updating only this one file's signatures, not hunting down 3 duplicated `compactMap { ... ChatMessage? in }` blocks.
2. **All `AnyCodable` accessor calls live in `EventInterpreter`** (one file). Inlining `as?` is a single-file edit.
3. **`SessionCoordinator` and `HistoryLoader` only consume `OpenClawChatMessage` through `ChatMessageConverter`** — they pass it in as an opaque value. They never touch its fields directly, so vendoring doesn't ripple.

**What stays coupled regardless of refactor:** the wire-format protocol itself (`agent:channel:label:uuid` session keys, the 5-stream event taxonomy, the `lifecycle/assistant/thinking/tool/item/command_output` stream names, the `role/state/toolCallId/toolName` message fields). These are the contract with the gateway server; replacing the SDK doesn't change them. To change them is a different product decision, not a refactor.

### Q2 — Unused SDK Capabilities as Future-Feature Reference

The SDK contains mature implementations that we currently don't use but that map cleanly to plausible future work. Listed by "what we'd build next" rather than "what's in the SDK":

| Future feature candidate | SDK reference (file path) | What we'd learn / reuse |
|---|---|---|
| **Richer tool-call bubbles** (emoji, verb like "Reading", auto detail extraction) | `OpenClawKit/Sources/OpenClawKit/ToolDisplay.swift` — `ToolDisplayRegistry.resolve(name:args:meta:) -> ToolDisplaySummary` | Config-driven (`tool-display.json` in `OpenClawKitResources.bundle`) — adding a new tool to the display map needs no app code. Already has special handling for `read`/`write`/`edit`/`attach` (path + offset + limit), and `shortenHomeInString` for `/Users/...` → `~`. **Note:** we explicitly did NOT adopt this in Task 2 because it changes the bubble text format. When we're ready to break the formatter-test pin, this is a self-contained upgrade. |
| **Better tool-result rendering** (e.g., "3 nodes found" summary, error detection) | `OpenClawChatUI/Sources/OpenClawChatUI/ToolResultTextFormatter.swift` — internal, but the algorithms are the reference | `renderDictionary` (status/error/message extraction), `renderNodesSummary` (custom summary for the `nodes` tool), `sanitizeError` (truncate to 220 chars, strip agent=action= prefix). Currently our `formatToolResultText` just pretty-prints JSON. Adopting these patterns (or making the formatter public) would be a small follow-up. |
| **Main session concept** (a designated "home" session per gateway) | `OpenClawChatUI/Sources/OpenClawChatUI/ChatViewModel.swift:1088` — `baseKey = "ios-\(UUID().uuidString.lowercased())"` and `resolvedMainSessionKey` | The SDK has a "main" session key per profile. If we add a "primary session" feature (home screen shortcut, default-open-on-launch), this is the SDK's pattern. We have no equivalent today; `SessionKey.makeNew` is just for the create-session path. |
| **Legacy session key aliasing** (`"main"` ↔ `agent:main:main` matching, case-insensitive) | `OpenClawChatUI/Sources/OpenClawChatUI/ChatViewModel+SessionKeys.swift` — `matchesCurrentSessionKey(incoming:current:mainSessionKey:)` | Our `loadedNetworkHistory` session-mismatch check at VM line 681 does a plain string compare. If the gateway ever sends `"main"` and we hold `"agent:main:main"`, our check would falsely drop. The SDK's `matchesCurrentSessionKey` handles this. Currently safe because we always read `vm.selectedSession?.key` (which is already in the canonical form) — but if we ever change that, this is the trap to avoid. |
| **Advanced markdown rendering** (link safety, code-block language hints, inline math) | `OpenClawChatUI/Sources/OpenClawChatUI/ChatMarkdownPreprocessor.swift`, `ChatMarkdownRenderer.swift` | We use `MarkdownDisplayView` package directly; the SDK's preprocessor is a different approach. If we hit edge cases (e.g., embedded HTML, very long lines), these are reference implementations. |
| **Enhanced chat input** (drag-drop attachments, paste image, voice input) | `OpenClawChatUI/Sources/OpenClawChatUI/ChatComposerTextView.swift`, `ChatViewModel+Attachments.swift` | We have a plain `TextField` in `ChatInputView.swift`. The SDK's composer is a `UITextView` wrapper with attachment support. Not on roadmap now, but a known upgrade path. |
| **Canvas / A2UI** (the SDK already has stubs and full impls) | `OpenClawKit/Sources/OpenClawKit/Canvas*`, OpenClawChatUI/CanvasA2UI*.swift | Our app has stub `canvas.*` handlers in `NodeCommandRouter.swift`. If/when we promote a canvas handler from stub to real, the SDK has the full protocol implementation as reference. |

**Pattern for "adopt later"**: each row above is a self-contained follow-up task, NOT a refactor. The current refactor positions us to take any of them without re-plumbing — because the architecture now has clear boundaries (the 4 collaborators, the 2 utility modules, the 1 converter file).

### Plan Tweaks Made For Migration Friendliness

This refactor was already migration-friendly by design, but two small choices in Tasks 2 and 8 deserve a footnote for the implementer:

- **Task 2 step 4-7**: `MessageFormatters` lives in `Core/Utilities/` (app target) — not as an extension on an SDK type. This means vendoring never needs to touch this file. If we later decide to switch to SDK's `ToolDisplayRegistry`, we replace `formatToolCallBubbleText`'s body with a call to `ToolDisplayRegistry.resolve(...)` and re-shape the bubble view. The function's callers (in `EventInterpreter` and `ChatMessageConverter`) don't change.
- **Task 8 step 1**: `EventInterpreter` is the ONLY file that calls SDK's `AnyCodable.stringValue` etc. The other 3 collaborators consume already-decoded Swift values. So if we ever want to drop the `AnyCodable+Helpers` dependency, we touch one file.

### When NOT to Migrate Out of SDK

The SDK is `../openclaw/apps/shared/OpenClawKit` — it's a sibling project, not a third-party dependency. We control both sides. Migration should only happen if:

1. The SDK is being **deprecated** (gateway server contract changes and the SDK is no longer maintained).
2. The SDK is being **forked** to a different name/location, and we want to avoid the dependency pointer.

For routine feature work or bug fixes, the SDK is the canonical source of truth for the wire format and we should consume it, not vendor it.

## Verification (End-to-End)

After all 10 tasks:

1. `wc -l SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` — should be <300.
2. `ls SmartChatApp/Features/NativeChat/Internal/` — 4 files.
3. `ls SmartChatApp/Core/Utilities/` — 2 files.
4. `ls SmartChatApp/Models/` — `CardData.swift`, `GatewayProfile.swift`, `SessionKey.swift`.
5. `xcodebuild test` — all 50 tests pass.
6. `make install` — installs to iPhone.
7. Manual smoke (Task 10 step 7) — all 7 user flows work unchanged.
