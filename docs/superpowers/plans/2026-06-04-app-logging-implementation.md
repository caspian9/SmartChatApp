# App Logging System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an in-app logging system that captures `os_log` calls into a viewable, filterable, copyable buffer controlled by Settings toggles, while preserving system Console output.

**Architecture:** Introduce `AppLogger` wrapper backed by a `LogRingBuffer` (cap 2000). All 10 existing files migrate from raw `os_log` / `Logger` to `AppLogger.log(_, category:)`. `ConfigurationManager` exposes 4 toggle `@Published Bool`s wired to `AppLogger.setEnabled(_, _)`. New `DebugLogsView` provides live tail / filter chips / search / pause / copy. Settings gains a "Debug & Logs" section after About. The existing SDK-side `Discovery Logs` viewer and its two SDK toggles remain untouched.

**Tech Stack:** Swift 5+, SwiftUI, Combine (`@Published`), XCTest, OSLog/Logger, XcodeGen for project regeneration.

---

## Spec Reference

- Spec: [`/docs/spec/2026-06-04-app-logging-design.md`](../../spec/2026-06-04-app-logging-design.md)
- Sections referenced: D1–D5 (decisions), §4 (architecture), §5 (data model), §6 (API), §7 (Settings UI), §8 (viewer), §9 (migration), §11 (acceptance)

## Source Convention Notes (spec deviation)

The spec §9 says "保留 `SMAlog:` 前缀". Inspection shows `SessionManager.swift` actually uses `log:` prefix, not `SMAlog:`. To eliminate the inconsistency while preserving the grep workflow:

- **At call sites**, the message string passed to `AppLogger.log(...)` does **not** include the `SMAlog:` / `log:` prefix. Strip both during migration.
- **AppLogger** prepends `SMAlog: ` when writing to `OSLog`. Existing `grep SMAlog:` workflows on Console.app continue to work, and now apply uniformly to all categories (including Network).
- **LogEntry** stores the raw message (no prefix) so `DebugLogsView` lines stay short.

This is a small deviation from the literal spec; same outcome, less manual maintenance.

## File Structure

**Create (3 files):**
- `SmartChatApp/Core/Services/AppLogger.swift` — `LogEntry`, `LogCategory`, `LogLevel`, `LogRingBuffer`, `AppLogger`
- `SmartChatApp/Features/Settings/DebugLogsView.swift` — viewer UI
- `SmartChatAppTests/AppLoggerTests.swift` — unit tests for `LogRingBuffer` + `AppLogger`

**Modify (12 files):**
- `SmartChatApp/Core/Services/ConfigurationManager.swift` — add 4 `@Published Bool` + sync wiring
- `SmartChatApp/Features/Settings/SettingsView.swift` — add `Debug & Logs` section
- `SmartChatApp/Core/Network/SessionManager.swift` — migrate (22 calls)
- `SmartChatApp/Core/Services/ProfileManager.swift` — migrate (7 calls)
- `SmartChatApp/Core/Services/MessageCache.swift` — migrate (9 calls)
- `SmartChatApp/Core/Services/MarkdownCache.swift` — remove unused `markdownLog` declaration (0 calls)
- `SmartChatApp/Core/Services/CollapseStateCache.swift` — migrate (3 calls)
- `SmartChatApp/Core/Services/MarkdownStreamManager.swift` — migrate (11 calls)
- `SmartChatApp/Features/NativeChat/NativeChatView.swift` — migrate (12 calls)
- `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` — migrate (74 calls; biggest)
- `SmartChatApp/Features/NativeChat/SessionPickerView.swift` — migrate (1 call)
- `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` — migrate (10 calls)
- `CLAUDE.md` — document `AppLogger` and the new Settings section

**XcodeGen note:** `project.yml` `sources: - SmartChatApp` and `sources: - SmartChatAppTests` use folder globs, so new `.swift` files are picked up automatically by `xcodegen generate`. No `project.yml` edit needed.

## Build & Test Commands

Use these throughout the plan:

```bash
# Regenerate Xcode project (run after creating new files)
xcodegen generate

# Run unit tests
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO

# Build only (faster, when verifying compilation)
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO

# Migration residue check (after Phase D)
grep -rnE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:' SmartChatApp --include='*.swift' | grep -v AppLogger.swift
```

---

## Phase A — AppLogger Foundation

### Task 1: LogRingBuffer (pure data structure, TDD)

Build a value-type ring buffer first so it can be tested in isolation, without the singleton or main actor.

**Files:**
- Create: `SmartChatApp/Core/Services/AppLogger.swift`
- Create: `SmartChatAppTests/AppLoggerTests.swift`

- [ ] **Step 1: Write the failing tests**

`SmartChatAppTests/AppLoggerTests.swift`:

```swift
import XCTest
@testable import SmartChatApp

final class LogRingBufferTests: XCTestCase {

    private func entry(_ msg: String) -> LogEntry {
        LogEntry(id: UUID(), ts: Date(), category: .network, level: .debug, message: msg)
    }

    func test_append_storesEntry() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        XCTAssertEqual(buf.entries.map(\.message), ["a"])
    }

    func test_append_underCapacity_keepsAll() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        XCTAssertEqual(buf.entries.map(\.message), ["a", "b"])
    }

    func test_append_atCapacity_keepsAll() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.append(entry("c"))
        XCTAssertEqual(buf.entries.map(\.message), ["a", "b", "c"])
    }

    func test_append_overCapacity_evictsOldest() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.append(entry("c"))
        buf.append(entry("d"))
        XCTAssertEqual(buf.entries.map(\.message), ["b", "c", "d"])
    }

    func test_append_farOverCapacity_keepsLastNOnly() {
        var buf = LogRingBuffer(capacity: 2)
        for i in 0..<10 {
            buf.append(entry("\(i)"))
        }
        XCTAssertEqual(buf.entries.map(\.message), ["8", "9"])
    }

    func test_clear_emptiesBuffer() {
        var buf = LogRingBuffer(capacity: 3)
        buf.append(entry("a"))
        buf.append(entry("b"))
        buf.clear()
        XCTAssertTrue(buf.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Verify the tests fail**

```bash
xcodegen generate
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

Expected: build error "cannot find type 'LogEntry' in scope" or "cannot find type 'LogRingBuffer' in scope".

- [ ] **Step 3: Create AppLogger.swift with data types and `LogRingBuffer`**

`SmartChatApp/Core/Services/AppLogger.swift`:

```swift
import Foundation
import OSLog

enum LogCategory: String, CaseIterable, Codable {
    case network    = "network"
    case cache      = "cache"
    case nativeChat = "nativeChat"
    case markdown   = "markdown"

    var displayName: String {
        switch self {
        case .network:    return "Network"
        case .cache:      return "Cache"
        case .nativeChat: return "NativeChat"
        case .markdown:   return "Markdown"
        }
    }
}

enum LogLevel: String, Codable {
    case debug, info, warning, error

    var osType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let category: LogCategory
    let level: LogLevel
    let message: String
}

struct LogRingBuffer {
    let capacity: Int
    private(set) var entries: [LogEntry] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }
}
```

- [ ] **Step 4: Verify the tests pass**

```bash
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `LogRingBufferTests` 6 tests PASS, all other tests still pass.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Core/Services/AppLogger.swift SmartChatAppTests/AppLoggerTests.swift project.yml SmartChatApp.xcodeproj
git commit -m "feat(logging): add LogEntry, LogCategory, LogLevel, LogRingBuffer"
```

---

### Task 2: AppLogger singleton + toggle gating (TDD)

Add the singleton wrapper around `LogRingBuffer` with per-category enable flags. Test that disabled categories do not enter the buffer.

**Files:**
- Modify: `SmartChatApp/Core/Services/AppLogger.swift` (append)
- Modify: `SmartChatAppTests/AppLoggerTests.swift` (append new test class)

- [ ] **Step 1: Append failing tests**

Append to `SmartChatAppTests/AppLoggerTests.swift`:

```swift
@MainActor
final class AppLoggerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AppLogger.shared.clear()
        for cat in LogCategory.allCases {
            AppLogger.shared.setEnabled(cat, false)
        }
    }

    func test_log_disabledCategory_doesNotEnterBuffer() {
        AppLogger.shared.setEnabled(.network, false)
        AppLogger.log("hello", category: .network)
        XCTAssertTrue(AppLogger.shared.entries.isEmpty)
    }

    func test_log_enabledCategory_entersBuffer() {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("hello", category: .network)
        XCTAssertEqual(AppLogger.shared.entries.count, 1)
        XCTAssertEqual(AppLogger.shared.entries.first?.message, "hello")
        XCTAssertEqual(AppLogger.shared.entries.first?.category, .network)
    }

    func test_log_onlyEnabledCategoriesEnterBuffer() {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.shared.setEnabled(.cache, false)
        AppLogger.log("net", category: .network)
        AppLogger.log("cache", category: .cache)
        XCTAssertEqual(AppLogger.shared.entries.map(\.message), ["net"])
    }

    func test_setEnabled_falseAfterTrue_subsequentLogsDropped() {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("a", category: .network)
        AppLogger.shared.setEnabled(.network, false)
        AppLogger.log("b", category: .network)
        XCTAssertEqual(AppLogger.shared.entries.map(\.message), ["a"])
    }

    func test_clear_emptiesEntries() {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("a", category: .network)
        AppLogger.log("b", category: .network)
        AppLogger.shared.clear()
        XCTAssertTrue(AppLogger.shared.entries.isEmpty)
    }

    func test_log_level_isCapturedInEntry() {
        AppLogger.shared.setEnabled(.network, true)
        AppLogger.log("warn msg", category: .network, level: .warning)
        XCTAssertEqual(AppLogger.shared.entries.first?.level, .warning)
    }
}
```

- [ ] **Step 2: Verify the tests fail**

```bash
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: build error "cannot find 'AppLogger' in scope".

- [ ] **Step 3: Append AppLogger to AppLogger.swift**

Append to `SmartChatApp/Core/Services/AppLogger.swift`:

```swift
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    private static let capacity = 2000
    @Published private var buffer = LogRingBuffer(capacity: AppLogger.capacity)
    private var enabledCategories: Set<LogCategory> = []

    private let osLogs: [LogCategory: OSLog] = [
        .network:    OSLog(subsystem: "SmartChatApp", category: "Network"),
        .cache:      OSLog(subsystem: "SmartChatApp", category: "Cache"),
        .nativeChat: OSLog(subsystem: "SmartChatApp", category: "NativeChat"),
        .markdown:   OSLog(subsystem: "SmartChatApp", category: "Markdown"),
    ]

    var entries: [LogEntry] { buffer.entries }

    private init() {}

    func setEnabled(_ category: LogCategory, _ on: Bool) {
        if on { enabledCategories.insert(category) }
        else  { enabledCategories.remove(category) }
    }

    func clear() {
        buffer.clear()
    }

    /// Main log entry point. Always writes to OSLog; writes to the in-memory
    /// buffer only when the category is enabled. Safe to call from any thread.
    static func log(_ message: String,
                    category: LogCategory,
                    level: LogLevel = .debug) {
        // OSLog: always write, prefix preserved for grep workflow.
        let osLog = MainActor.assumeIsolated { shared.osLogs[category]! }
            // assumeIsolated is safe: osLogs is immutable after init.
        os_log("%{public}@", log: osLog, type: level.osType, "SMAlog: " + message)

        // Buffer: hop to main actor, gate on enabled category.
        let entry = LogEntry(id: UUID(),
                             ts: Date(),
                             category: category,
                             level: level,
                             message: message)
        Task { @MainActor in
            guard shared.enabledCategories.contains(category) else { return }
            shared.buffer.append(entry)
        }
    }
}
```

> Note: `MainActor.assumeIsolated` is used only to read the immutable `osLogs` dictionary. If the compiler rejects it in non-main-actor contexts (Swift 5/6 mode varies), replace with a top-level `private let osLogs: [LogCategory: OSLog] = [...]` outside the class. The behavior is identical.

- [ ] **Step 4: Verify the tests pass**

```bash
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: 6 new `AppLoggerTests` PASS. The async `Task { @MainActor in ... }` resolves before the test's next statement on the main actor because the test methods are themselves `@MainActor` — the Task is enqueued before the assertion, and the assertion's actor hop runs after it.

If a flakiness emerges, add `await Task.yield()` before assertions, e.g.:

```swift
AppLogger.log("hello", category: .network)
await Task.yield()
XCTAssertEqual(AppLogger.shared.entries.count, 1)
```

(And mark the test methods `async`.)

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Core/Services/AppLogger.swift SmartChatAppTests/AppLoggerTests.swift
git commit -m "feat(logging): add AppLogger singleton with per-category toggle gating"
```

---

## Phase B — Settings Wiring

### Task 3: ConfigurationManager toggles + AppLogger sync

Add 4 UserDefaults-backed toggles. On `init` and `didSet`, sync to `AppLogger.shared.setEnabled(_, _)`.

**Files:**
- Modify: `SmartChatApp/Core/Services/ConfigurationManager.swift`

- [ ] **Step 1: Add UserDefaults keys**

In `ConfigurationManager.Keys` enum, add:

```swift
static let logsNetwork    = "openclaw_logs_network"
static let logsCache      = "openclaw_logs_cache"
static let logsNativeChat = "openclaw_logs_native_chat"
static let logsMarkdown   = "openclaw_logs_markdown"
```

- [ ] **Step 2: Add @Published properties with didSet**

Add inside the class (after `voiceWakeEnabled`, before `locationMode`):

```swift
@Published var logsNetwork: Bool {
    didSet {
        defaults.set(logsNetwork, forKey: Keys.logsNetwork)
        Task { @MainActor in AppLogger.shared.setEnabled(.network, logsNetwork) }
    }
}

@Published var logsCache: Bool {
    didSet {
        defaults.set(logsCache, forKey: Keys.logsCache)
        Task { @MainActor in AppLogger.shared.setEnabled(.cache, logsCache) }
    }
}

@Published var logsNativeChat: Bool {
    didSet {
        defaults.set(logsNativeChat, forKey: Keys.logsNativeChat)
        Task { @MainActor in AppLogger.shared.setEnabled(.nativeChat, logsNativeChat) }
    }
}

@Published var logsMarkdown: Bool {
    didSet {
        defaults.set(logsMarkdown, forKey: Keys.logsMarkdown)
        Task { @MainActor in AppLogger.shared.setEnabled(.markdown, logsMarkdown) }
    }
}
```

- [ ] **Step 3: Initialize in `init()`**

In `init()` (after `self.voiceWakeEnabled = ...` line), add:

```swift
self.logsNetwork    = defaults.object(forKey: Keys.logsNetwork)    as? Bool ?? false
self.logsCache      = defaults.object(forKey: Keys.logsCache)      as? Bool ?? false
self.logsNativeChat = defaults.object(forKey: Keys.logsNativeChat) as? Bool ?? false
self.logsMarkdown   = defaults.object(forKey: Keys.logsMarkdown)   as? Bool ?? false
```

At the **end** of `init()` (after the `locationMode` block), sync the loaded values into `AppLogger`:

```swift
let initialNetwork    = self.logsNetwork
let initialCache      = self.logsCache
let initialNativeChat = self.logsNativeChat
let initialMarkdown   = self.logsMarkdown
Task { @MainActor in
    AppLogger.shared.setEnabled(.network,    initialNetwork)
    AppLogger.shared.setEnabled(.cache,      initialCache)
    AppLogger.shared.setEnabled(.nativeChat, initialNativeChat)
    AppLogger.shared.setEnabled(.markdown,   initialMarkdown)
}
```

(Reading the properties into locals avoids capturing `self` in the Task closure during `init`.)

- [ ] **Step 4: Build to verify compilation**

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Core/Services/ConfigurationManager.swift
git commit -m "feat(logging): add 4 log category toggles to ConfigurationManager"
```

---

### Task 4: SettingsView "Debug & Logs" section (toggles only)

Add the new section with the 4 toggles, Clear button, and a placeholder NavigationLink (the destination view comes in Task 5). This way the toggle behavior is testable on-device before the viewer exists.

**Files:**
- Modify: `SmartChatApp/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add Debug & Logs section after About**

Locate the `Section("About") { ... }` block (around line 150). **After** its closing brace, insert:

```swift
Section("Debug & Logs") {
    Toggle("Network Logs", isOn: $config.logsNetwork)
    Toggle("Cache Logs", isOn: $config.logsCache)
    Toggle("NativeChat Logs", isOn: $config.logsNativeChat)
    Toggle("Markdown Logs", isOn: $config.logsMarkdown)

    NavigationLink("Debug Logs Viewer") {
        // TODO: DebugLogsView() — replaced in Task 5
        Text("Debug Logs Viewer placeholder")
    }

    Button("Clear Logs") {
        AppLogger.shared.clear()
    }
    .foregroundColor(.red)
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/Settings/SettingsView.swift
git commit -m "feat(logging): add Debug & Logs section to SettingsView"
```

---

## Phase C — Debug Logs Viewer

### Task 5: DebugLogsView shell with live tail

Create the viewer with a list bound to `AppLogger.shared.entries`. No filters yet — just rendering + auto-scroll.

**Files:**
- Create: `SmartChatApp/Features/Settings/DebugLogsView.swift`
- Modify: `SmartChatApp/Features/Settings/SettingsView.swift` (replace placeholder)

- [ ] **Step 1: Create DebugLogsView.swift**

`SmartChatApp/Features/Settings/DebugLogsView.swift`:

```swift
import SwiftUI
import UIKit

struct DebugLogsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var logger = AppLogger.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(logger.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: logger.entries.count) { _, _ in
                if let lastId = logger.entries.last?.id {
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func entryRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: entry.ts))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text("[\(entry.category.displayName)]")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Replace SettingsView placeholder with `DebugLogsView()`**

In `SettingsView.swift`, find the placeholder:

```swift
NavigationLink("Debug Logs Viewer") {
    // TODO: DebugLogsView() — replaced in Task 5
    Text("Debug Logs Viewer placeholder")
}
```

Replace with:

```swift
NavigationLink("Debug Logs Viewer") {
    DebugLogsView()
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodegen generate
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add SmartChatApp/Features/Settings/DebugLogsView.swift SmartChatApp/Features/Settings/SettingsView.swift project.yml SmartChatApp.xcodeproj
git commit -m "feat(logging): add DebugLogsView with live tail"
```

---

### Task 6: DebugLogsView filter chips

Add 4 chips for category filtering at the top.

**Files:**
- Modify: `SmartChatApp/Features/Settings/DebugLogsView.swift`

- [ ] **Step 1: Add filter state and derived list**

In `DebugLogsView`, add state and computed property below `@ObservedObject`:

```swift
@State private var enabledChips: Set<LogCategory> = Set(LogCategory.allCases)

private var displayEntries: [LogEntry] {
    logger.entries.filter { enabledChips.contains($0.category) }
}
```

- [ ] **Step 2: Replace `logger.entries` references in body with `displayEntries`**

Two places to change in the body:

```swift
ForEach(logger.entries) { entry in
```
→
```swift
ForEach(displayEntries) { entry in
```

```swift
.onChange(of: logger.entries.count) { _, _ in
    if let lastId = logger.entries.last?.id {
```
→
```swift
.onChange(of: displayEntries.count) { _, _ in
    if let lastId = displayEntries.last?.id {
```

- [ ] **Step 3: Add chips row above the ScrollView**

Wrap the existing `ScrollViewReader { ... }` body in a `VStack(spacing: 0)`, and add chips above:

```swift
var body: some View {
    VStack(spacing: 0) {
        chipsBar
        scrollList
    }
    .navigationTitle("Debug Logs")
    .navigationBarTitleDisplayMode(.inline)
}

private var chipsBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(LogCategory.allCases, id: \.self) { cat in
                chip(for: cat)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private func chip(for cat: LogCategory) -> some View {
    let on = enabledChips.contains(cat)
    return Button {
        if on { enabledChips.remove(cat) }
        else  { enabledChips.insert(cat) }
    } label: {
        Text(cat.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? theme.primary : Color.gray.opacity(0.2))
            .foregroundColor(on ? .white : theme.textSecondary)
            .clipShape(Capsule())
    }
    .buttonStyle(.plain)
}

private var scrollList: some View {
    ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(displayEntries) { entry in
                    entryRow(entry)
                        .id(entry.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: displayEntries.count) { _, _ in
            if let lastId = displayEntries.last?.id {
                DispatchQueue.main.async {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/Settings/DebugLogsView.swift
git commit -m "feat(logging): add category filter chips to DebugLogsView"
```

---

### Task 7: DebugLogsView search bar

Add a free-text search filter on the message.

**Files:**
- Modify: `SmartChatApp/Features/Settings/DebugLogsView.swift`

- [ ] **Step 1: Add search state and extend filter**

Add state next to `enabledChips`:

```swift
@State private var searchText: String = ""
```

Update `displayEntries`:

```swift
private var displayEntries: [LogEntry] {
    logger.entries.filter { entry in
        guard enabledChips.contains(entry.category) else { return false }
        if searchText.isEmpty { return true }
        return entry.message.localizedCaseInsensitiveContains(searchText)
    }
}
```

- [ ] **Step 2: Add search field below chips**

Update `body` to insert a search row:

```swift
var body: some View {
    VStack(spacing: 0) {
        chipsBar
        searchBar
        scrollList
    }
    .navigationTitle("Debug Logs")
    .navigationBarTitleDisplayMode(.inline)
}

private var searchBar: some View {
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
        TextField("Search", text: $searchText)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        if !searchText.isEmpty {
            Button { searchText = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.gray.opacity(0.1))
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add SmartChatApp/Features/Settings/DebugLogsView.swift
git commit -m "feat(logging): add search bar to DebugLogsView"
```

---

### Task 8: DebugLogsView Pause/Resume + Copy

Add toolbar buttons. Pause freezes the displayed list (snapshot); Copy puts the visible lines on the clipboard.

**Files:**
- Modify: `SmartChatApp/Features/Settings/DebugLogsView.swift`

- [ ] **Step 1: Add pause state and frozen snapshot**

Add state:

```swift
@State private var isPaused: Bool = false
@State private var frozenEntries: [LogEntry] = []
```

Update `displayEntries` to read from frozen snapshot when paused:

```swift
private var displayEntries: [LogEntry] {
    let source = isPaused ? frozenEntries : logger.entries
    return source.filter { entry in
        guard enabledChips.contains(entry.category) else { return false }
        if searchText.isEmpty { return true }
        return entry.message.localizedCaseInsensitiveContains(searchText)
    }
}
```

- [ ] **Step 2: Add a Copy formatter**

Add ISO formatter at file scope (above `struct DebugLogsView`):

```swift
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
```

Inside `DebugLogsView`, add:

```swift
private func copyFormatted() {
    let text = displayEntries
        .map { "\(isoFormatter.string(from: $0.ts)) [\($0.category.displayName)] \($0.message)" }
        .joined(separator: "\n")
    UIPasteboard.general.string = text
}
```

- [ ] **Step 3: Add toolbar buttons**

Add to `body`:

```swift
.navigationTitle("Debug Logs")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItemGroup(placement: .topBarTrailing) {
        Button(isPaused ? "Resume" : "Pause") {
            if isPaused {
                isPaused = false
                frozenEntries = []
            } else {
                frozenEntries = logger.entries
                isPaused = true
            }
        }
        Button("Copy") { copyFormatted() }
            .disabled(displayEntries.isEmpty)
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SmartChatApp/Features/Settings/DebugLogsView.swift
git commit -m "feat(logging): add Pause/Resume and Copy to DebugLogsView"
```

---

## Phase D — Migration

### Migration Convention

For every file in Phase D, perform these substitutions:

1. **Delete the declaration line(s)** at the top of the file:
   - `private let xxxLog = OSLog(subsystem: "...", category: "...")`
   - `private let logger = Logger(subsystem: "...", category: "...")`
   - (Keep the `import OSLog` line only if the file uses OSLog types elsewhere; in all migrated files in this plan, the only OSLog use is the deleted logger, so `import OSLog` can also go.)

2. **Replace each call:**
   - `os_log("SMAlog: <fmt>", log: xxxLog, type: .debug, <args>)` → `AppLogger.log("<rendered>", category: .xxx)`
   - `os_log("SMAlog: <fmt>", log: xxxLog, type: .error, <args>)` → `AppLogger.log("<rendered>", category: .xxx, level: .error)`
   - `logger.log("SMAlog: <text>")` → `AppLogger.log("<text>", category: .xxx)` (strip prefix)
   - `logger.log("log: <text>")` → `AppLogger.log("<text>", category: .xxx)` (strip prefix, applies to `SessionManager`)
   - `xxxLog.log("SMAlog: ...")` → same pattern (applies to `ProfileManager`)

3. **Render `os_log` format strings to Swift interpolation:**
   - `%{public}s` / `%{public}@` → `\(value)`
   - `%{public}d` → `\(value)`
   - `%{public}.1f` → `\(String(format: "%.1f", value))`
   - `%{public}03d` (used for boolean-as-int) → `\(value ? 1 : 0)` (the original was rendering Bool→Int; keep the same semantics)

4. **Strip `SMAlog: ` and `log: ` prefixes** from the message string. `AppLogger.log` re-adds `SMAlog: ` automatically when writing to `OSLog`.

5. **Per-file verification:** after editing each file, build to ensure no compile error, then `grep` to confirm no residue:

```bash
grep -nE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:' <file>
# Expected: no output
```

---

### Task 9: Migrate Network category (SessionManager + ProfileManager)

**Files:**
- Modify: `SmartChatApp/Core/Network/SessionManager.swift` (22 calls, uses `Logger` with `log:` prefix)
- Modify: `SmartChatApp/Core/Services/ProfileManager.swift` (7 calls, uses `Logger` with `SMAlog: [ProfileManager]` prefix)

- [ ] **Step 1: SessionManager — delete declaration**

Open `SmartChatApp/Core/Network/SessionManager.swift`. Delete line 9:

```swift
private let logger = Logger(subsystem: "SmartChatApp", category: "SessionManager")
```

Delete the `import OSLog` line if present and unused elsewhere in the file.

- [ ] **Step 2: SessionManager — replace 22 call sites**

For every `logger.log("log: <text>")` call in this file, replace with `AppLogger.log("<text>", category: .network)` — strip the `log: ` prefix.

Example (line 113):

```swift
// BEFORE
logger.log("log: Operator connected to gateway")
// AFTER
AppLogger.log("Operator connected to gateway", category: .network)
```

Example (line 139):

```swift
// BEFORE
logger.log("log: Auth error: \(error.message)\(requestIdStr)")
// AFTER
AppLogger.log("Auth error: \(error.message)\(requestIdStr)", category: .network)
```

For lines that semantically convey an error (e.g. line 139 "Auth error", 143 "Connection error", 193 "Node connection error", 452 "Invalid profile URL for reconnect", 491 "Reconnect failed"), also pass `level: .error`:

```swift
AppLogger.log("Auth error: \(error.message)\(requestIdStr)", category: .network, level: .error)
```

- [ ] **Step 3: SessionManager — verify**

```bash
grep -nE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:|logger\.log\(' SmartChatApp/Core/Network/SessionManager.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: ProfileManager — delete declaration**

Open `SmartChatApp/Core/Services/ProfileManager.swift`. Delete line 4:

```swift
private let profileLog = Logger(subsystem: "SmartChatApp", category: "ProfileManager")
```

Delete the `import OSLog` line.

- [ ] **Step 5: ProfileManager — replace 7 call sites**

For every `profileLog.log("SMAlog: [ProfileManager] <text>")` call, replace with `AppLogger.log("[ProfileManager] <text>", category: .network)` — strip the `SMAlog: ` prefix but keep `[ProfileManager]` for context inside the message.

Example (line 30):

```swift
// BEFORE
profileLog.log("SMAlog: [ProfileManager] Loaded \(self.profiles.count) profiles, active: \(self.activeProfile?.name ?? "none")")
// AFTER
AppLogger.log("[ProfileManager] Loaded \(self.profiles.count) profiles, active: \(self.activeProfile?.name ?? "none")", category: .network)
```

For lines 32, 43, 117 (failures), add `level: .error`.

- [ ] **Step 6: ProfileManager — verify**

```bash
grep -nE 'os_log\(|Logger\(subsystem:|profileLog\.' SmartChatApp/Core/Services/ProfileManager.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add SmartChatApp/Core/Network/SessionManager.swift SmartChatApp/Core/Services/ProfileManager.swift
git commit -m "refactor(logging): migrate Network category to AppLogger"
```

---

### Task 10: Migrate Cache category

**Files:**
- Modify: `SmartChatApp/Core/Services/MessageCache.swift` (9 calls)
- Modify: `SmartChatApp/Core/Services/MarkdownCache.swift` (0 calls — remove declaration only)
- Modify: `SmartChatApp/Core/Services/CollapseStateCache.swift` (3 calls)

- [ ] **Step 1: MessageCache — delete declaration**

Delete line 7:

```swift
private let osLog = OSLog(subsystem: "SmartChatApp", category: "MessageCache")
```

Delete `import OSLog` (line 4).

- [ ] **Step 2: MessageCache — replace 9 call sites**

Example (line 23):

```swift
// BEFORE
os_log("SMAlog: [MessageCache getMessages] sessionKey=%{public}s returning=%{public}d from_memory", log: osLog, type: .debug, String(sessionKey.prefix(8)), cached.count)
// AFTER
AppLogger.log("[MessageCache getMessages] sessionKey=\(String(sessionKey.prefix(8))) returning=\(cached.count) from_memory", category: .cache)
```

Apply the same pattern to lines 27, 61, 68, 127, 146, 171, 174, 178. All use `type: .debug` — keep `level` default.

- [ ] **Step 3: MarkdownCache — delete unused declaration**

Open `SmartChatApp/Core/Services/MarkdownCache.swift`. Delete line 4:

```swift
private let markdownLog = OSLog(subsystem: "SmartChatApp", category: "MarkdownCache")
```

Delete `import OSLog` (line 2) if no other OSLog use.

(There are 0 actual logger calls in this file — `grep -c 'os_log\(' SmartChatApp/Core/Services/MarkdownCache.swift` returned 0.)

- [ ] **Step 4: CollapseStateCache — delete declaration**

Delete line 5:

```swift
private let collapseLog = OSLog(subsystem: "SmartChatApp", category: "CollapseStateCache")
```

Delete `import OSLog` (line 3).

- [ ] **Step 5: CollapseStateCache — replace 3 call sites**

Line 70 (multi-line `os_log` call):

```swift
// BEFORE
os_log("SMAlog: [CollapseCache safeHeight] id=%{public}s totalHeight=%{public}.1f safeHeight=%{public}.1f lines=%{public}.1f",
       log: collapseLog, type: .debug,
       String(message.id.prefix(8)), totalHeight, safeHeight, lineCount)
// AFTER
AppLogger.log("[CollapseCache safeHeight] id=\(String(message.id.prefix(8))) totalHeight=\(String(format: "%.1f", totalHeight)) safeHeight=\(String(format: "%.1f", safeHeight)) lines=\(String(format: "%.1f", lineCount))", category: .cache)
```

Line 84:

```swift
AppLogger.log("[CollapseCache] precompute processed=\(messages.count) computed=\(computedCount) cacheSize=\(shouldCollapseCache.count)", category: .cache)
```

Line 126:

```swift
AppLogger.log("[CollapseCache] id=\(String(message.id.prefix(8))) text_len=\(text.count) lines=\(lineCount) height=\(String(format: "%.1f", textHeight))", category: .cache)
```

- [ ] **Step 6: Verify and build**

```bash
grep -nE 'os_log\(|OSLog\(subsystem:' SmartChatApp/Core/Services/MessageCache.swift SmartChatApp/Core/Services/MarkdownCache.swift SmartChatApp/Core/Services/CollapseStateCache.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add SmartChatApp/Core/Services/MessageCache.swift SmartChatApp/Core/Services/MarkdownCache.swift SmartChatApp/Core/Services/CollapseStateCache.swift
git commit -m "refactor(logging): migrate Cache category to AppLogger"
```

---

### Task 11: Migrate Markdown category

**Files:**
- Modify: `SmartChatApp/Core/Services/MarkdownStreamManager.swift` (11 calls)

- [ ] **Step 1: Delete declaration**

Delete line 6:

```swift
private let managerLog = OSLog(subsystem: "SmartChatApp.MarkdownStreamManager", category: "debug")
```

Delete `import OSLog` (line 4).

- [ ] **Step 2: Replace 11 call sites**

Pattern (e.g. line 40):

```swift
// BEFORE
os_log("SMAlog: [MarkdownHolder] begin() skipped (already begun) id=%{public}s", log: managerLog, type: .debug, String(messageId.prefix(8)))
// AFTER
AppLogger.log("[MarkdownHolder] begin() skipped (already begun) id=\(String(messageId.prefix(8)))", category: .markdown)
```

Lines to migrate: 40, 45, 55, 68, 74, 81, 86, 128, 138, 158, 167. All `type: .debug` — keep default level.

For line 68 (cumulative does not extend prev — this is a logic-warning condition), use `level: .warning`:

```swift
AppLogger.log("[MarkdownHolder] cumulative does not extend prev id=\(String(messageId.prefix(8))) prev_len=\(lastReceivedText.count) new_len=\(cumulative.count)", category: .markdown, level: .warning)
```

- [ ] **Step 3: Verify and build**

```bash
grep -nE 'os_log\(|OSLog\(subsystem:' SmartChatApp/Core/Services/MarkdownStreamManager.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add SmartChatApp/Core/Services/MarkdownStreamManager.swift
git commit -m "refactor(logging): migrate Markdown category to AppLogger"
```

---

### Task 12: Migrate NativeChat non-VM files (View + Picker + Bubble)

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/NativeChatView.swift` (12 calls)
- Modify: `SmartChatApp/Features/NativeChat/SessionPickerView.swift` (1 call)
- Modify: `SmartChatApp/Features/NativeChat/MessageBubbleView.swift` (10 calls)

- [ ] **Step 1: NativeChatView — delete declaration**

Open `SmartChatApp/Features/NativeChat/NativeChatView.swift`. Delete line 5:

```swift
private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatView")
```

Delete `import OSLog` (line 3).

- [ ] **Step 2: NativeChatView — replace 12 call sites**

All call sites use `logger.log("SMAlog: <text>")`. Replace each with `AppLogger.log("<text>", category: .nativeChat)`, stripping `SMAlog: ` prefix.

Example (line 30):

```swift
// BEFORE
logger.log("SMAlog: NativeChatView onAppear called")
// AFTER
AppLogger.log("NativeChatView onAppear called", category: .nativeChat)
```

Lines: 20, 30, 114, 117, 126, 128, 138, 152, 163, 170, 189, 200.

- [ ] **Step 3: SessionPickerView — delete declaration**

Open `SmartChatApp/Features/NativeChat/SessionPickerView.swift`. Delete line 5:

```swift
private let logger = Logger(subsystem: "SmartChatApp", category: "SessionPickerView")
```

Delete `import OSLog` (line 3).

- [ ] **Step 4: SessionPickerView — replace 1 call site**

Line 256:

```swift
// BEFORE
logger.log("SMAlog: SessionPickerView onAppear, sessions: \(self.sessions.count)")
// AFTER
AppLogger.log("SessionPickerView onAppear, sessions: \(self.sessions.count)", category: .nativeChat)
```

- [ ] **Step 5: MessageBubbleView — delete declaration**

Open `SmartChatApp/Features/NativeChat/MessageBubbleView.swift`. Delete line 4:

```swift
private let bubbleLog = OSLog(subsystem: "SmartChatApp.MessageBubble", category: "debug")
```

Delete `import OSLog` (line 2).

- [ ] **Step 6: MessageBubbleView — replace 10 call sites**

Lines 43, 61, 67, 75, 77, 81, 85, 310, 314, 320.

Example (line 43, the complex one with boundingRect inline):

```swift
// BEFORE
os_log("SMAlog: [collapse] id=%{public}s text_len=%{public}d lines=%{public}d height=%{public}.1f collapse=%{public}03d", log: bubbleLog, type: .debug, String(message.id.prefix(8)), message.text.count, cachedLineCount, message.text.boundingRect(with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height, cachedShouldCollapse ? 1 : 0)
// AFTER
let _bubbleHeight = message.text.boundingRect(with: CGSize(width: UIScreen.main.bounds.width * 0.65, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
AppLogger.log("[collapse] id=\(String(message.id.prefix(8))) text_len=\(message.text.count) lines=\(cachedLineCount) height=\(String(format: "%.1f", _bubbleHeight)) collapse=\(cachedShouldCollapse ? 1 : 0)", category: .nativeChat)
```

Example (line 61):

```swift
AppLogger.log("[computeLineCount] id=\(String(message.id.prefix(8))) text_len=\(message.text.count) height=\(String(format: "%.1f", textHeight)) count=\(count)", category: .nativeChat)
```

Example (line 310):

```swift
AppLogger.log("[collapseLineLimit] id=\(String(message.id.prefix(8))) state=\(message.state) isFresh=\(message.isFresh ? 1 : 0) -> nil (full text)", category: .nativeChat)
```

- [ ] **Step 7: Verify and build**

```bash
grep -nE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:' SmartChatApp/Features/NativeChat/NativeChatView.swift SmartChatApp/Features/NativeChat/SessionPickerView.swift SmartChatApp/Features/NativeChat/MessageBubbleView.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add SmartChatApp/Features/NativeChat/NativeChatView.swift SmartChatApp/Features/NativeChat/SessionPickerView.swift SmartChatApp/Features/NativeChat/MessageBubbleView.swift
git commit -m "refactor(logging): migrate NativeChat view files to AppLogger"
```

---

### Task 13: Migrate NativeChatViewModel (74 calls)

This file has the bulk of the migration. Isolate it as its own commit.

**Files:**
- Modify: `SmartChatApp/Features/NativeChat/NativeChatViewModel.swift` (74 calls — mix of `logger.log(...)` and `os_log(...)`)

- [ ] **Step 1: Delete declarations**

Delete lines 8 and 9:

```swift
private let logger = Logger(subsystem: "SmartChatApp", category: "NativeChatViewModel")
private let osLog = OSLog(subsystem: "SmartChatApp.NativeChatViewModel", category: "debug")
```

Delete `import OSLog` (line 4).

- [ ] **Step 2: Enumerate all call sites**

Get exact line numbers and content:

```bash
grep -nE 'logger\.log\(|os_log\(' SmartChatApp/Features/NativeChat/NativeChatViewModel.swift > /tmp/vm_log_sites.txt
wc -l /tmp/vm_log_sites.txt
```

Expected: 74 lines listed.

- [ ] **Step 3: Replace each call**

For each `logger.log("...")` call (no SMAlog prefix in most, some have it — strip if present):

```swift
// BEFORE
logger.log("Received message: \(...)")
// AFTER
AppLogger.log("Received message: \(...)", category: .nativeChat)
```

For each `os_log("SMAlog: <fmt>", log: osLog, type: .debug, <args>)`:

```swift
// BEFORE (line 613 example)
os_log("SMAlog: history msg[%{public}d] contentItems=%{public}d text_len=%{private}d role=%{public}s", log: osLog, type: .debug, index, msg.content.count, text.count, role)
// AFTER
AppLogger.log("history msg[\(index)] contentItems=\(msg.content.count) text_len=\(text.count) role=\(role)", category: .nativeChat)
```

**Note on `%{private}` markers**: the original had `%{public}d` for `text.count` swapped to `%{private}d` to hide message length in release. After migration, all values are in plain Swift strings — the OSLog `public/private` distinction no longer applies because we use `%{public}@` for the whole rendered message. If hiding message length in release is important, wrap the value: `(SOME_FLAG ? "\(text.count)" : "<redacted>")`. For this migration, default to public; the SMAlog logs are debug-only anyway.

For lines that emit error/warning semantics (search for "fail", "error", "missing"), pass `level: .error` or `level: .warning`. Examples to flag:
- Any "skipped" / "no holder" / "fallback" patterns: `.warning`
- Any "failed" / "error" patterns: `.error`

The rest: keep default `.debug`.

Work through `/tmp/vm_log_sites.txt` top-to-bottom, editing each occurrence with the `Edit` tool. Build after every ~15 substitutions to catch typos early.

- [ ] **Step 4: Verify and build**

```bash
grep -nE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:|logger\.log\(' SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
```

Expected: no output.

```bash
xcodebuild build \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run tests**

```bash
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: all tests PASS (including `NativeChatViewModelFormatterTests` which exercises this file's pure functions).

- [ ] **Step 6: Commit**

```bash
git add SmartChatApp/Features/NativeChat/NativeChatViewModel.swift
git commit -m "refactor(logging): migrate NativeChatViewModel to AppLogger"
```

---

## Phase E — Verification & Polish

### Task 14: Final residue sweep + CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Codebase-wide residue check**

```bash
grep -rnE 'os_log\(|Logger\(subsystem:|OSLog\(subsystem:' SmartChatApp --include='*.swift' | grep -v 'AppLogger.swift'
```

Expected: no output. (`AppLogger.swift` itself uses `OSLog` and `os_log` internally — that's the only allowed occurrence.)

If anything appears, treat as a missed migration: identify the file, apply the same migration pattern from the relevant Phase D task, build, commit as `refactor(logging): cleanup missed migration in <file>`.

- [ ] **Step 2: Full build + test**

```bash
xcodegen generate
xcodebuild test \
  -scheme SmartChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: BUILD + all tests PASS.

- [ ] **Step 3: Update CLAUDE.md**

Open `CLAUDE.md`. Locate the table under `### Key Components` (around line 50 of the Architecture section). Add a new row for `AppLogger`:

```markdown
| `AppLogger` | `Core/Services/` | App-wide log capture: writes to OSLog and an in-memory ring buffer (cap 2000). Per-category toggles in Settings. Viewable via Debug Logs Viewer. |
```

Also add a new section after `## Message Collapse Behavior` (or before `## Theme Configuration`):

```markdown
## Logging

The app uses `AppLogger` (`Core/Services/AppLogger.swift`) as the single entry point for all log emission. Call sites use:

```swift
AppLogger.log("message", category: .network)   // default level .debug
AppLogger.log("oops", category: .nativeChat, level: .error)
```

`AppLogger` always writes to `OSLog` (system Console) with the `SMAlog:` prefix preserved for grep workflows. It additionally writes to an in-memory ring buffer (`LogRingBuffer`, cap 2000) when the matching category toggle in Settings → Debug & Logs is on.

| Category | Files |
|----------|-------|
| `.network` | `SessionManager`, `ProfileManager` |
| `.cache` | `MessageCache`, `MarkdownCache`, `CollapseStateCache` |
| `.nativeChat` | `NativeChatView`, `NativeChatViewModel`, `SessionPickerView`, `MessageBubbleView` |
| `.markdown` | `MarkdownStreamManager` |

Direct use of `os_log` / `Logger(subsystem:)` is no longer permitted in app code — use `AppLogger.log(...)` instead. The SDK-side `Gateway Debug Logs` and `Discovery Debug Logs` toggles (in Settings → Gateway → Advanced) are separate from this system and control `OpenClawKit` internal logging.
```

Verify the markdown renders:

```bash
head -200 CLAUDE.md | tail -50
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document AppLogger and the Debug & Logs Settings section"
```

---

### Task 15: Manual end-to-end verification

This task is a checklist for the engineer to run on a Simulator (or device) before declaring the feature done. Each item maps back to the spec acceptance checklist (§11).

- [ ] **Step 1: Launch app, open Settings**

Build and run on `iPhone 17 Pro` Simulator. Scroll to the bottom of Settings — `Debug & Logs` section should appear with 4 toggles (off by default), `Debug Logs Viewer` link, and `Clear Logs` button (red).

- [ ] **Step 2: Toggle each category on**

Flip `NativeChat Logs` on. Navigate to NativeChat tab, send a message, then back to Settings → Debug Logs Viewer. Confirm log entries appear with timestamps and `[NativeChat]` category tag.

- [ ] **Step 3: Verify filter chips**

In Debug Logs Viewer, deselect the `NativeChat` chip. List should empty (only NativeChat entries existed). Re-enable.

- [ ] **Step 4: Verify search**

Type a substring known to appear in a recent log line (e.g. `scrollTrigger`). List should narrow. Clear search; list restores.

- [ ] **Step 5: Verify Pause/Resume**

Send another chat message, then immediately tap Pause. New log entries (from the in-flight stream) should NOT appear. Tap Resume — new entries since the pause should appear; the view should auto-scroll to bottom.

- [ ] **Step 6: Verify Copy**

Tap Copy. Switch to Notes (or any text field) and paste. Verify lines are formatted `<ISO timestamp> [<Category>] <message>`.

- [ ] **Step 7: Verify Clear**

Back to Settings, tap Clear Logs. Re-open Debug Logs Viewer. List should be empty.

- [ ] **Step 8: Verify toggle persistence**

With `Markdown Logs` enabled, kill the app. Relaunch. Open Settings → Debug & Logs. Confirm `Markdown Logs` is still on. Open Debug Logs Viewer; some markdown-category entries should already be present from launch-time activity.

- [ ] **Step 9: Verify SDK toggles untouched**

In Settings → Gateway → Advanced, confirm the original `Gateway Debug Logs`, `Discovery Debug Logs`, and `Discovery Logs` link are unchanged. Open Discovery Logs; confirm it still shows SDK `DebugLogEntry` snapshot behavior.

- [ ] **Step 10: Verify Console output**

In Console.app (or `log stream --predicate 'subsystem == "SmartChatApp"'`), confirm log lines from the app still appear with the `SMAlog:` prefix even when the in-app toggle is OFF (OSLog is always written).

- [ ] **Step 11: No commit needed**

This task does not produce code changes. If a defect is found, file a follow-up task and fix before declaring complete.

---

## Self-Review Notes (filled at plan-write time)

**Spec coverage:**
- D1 (unified viewer) → Tasks 5–8
- D2 (per-module toggles) → Tasks 3–4
- D3 (AppLogger wrapper + migration) → Tasks 1–2, 9–13
- D4 (ring buffer, mem-only) → Task 1
- D5 (live tail / chips / search / pause / copy) → Tasks 5–8
- §11 acceptance items → Task 15 maps to each

**Type consistency check:**
- `LogCategory.network/.cache/.nativeChat/.markdown` — used identically in all tasks
- `AppLogger.log(_, category:, level:)` signature — same call shape everywhere
- `ConfigurationManager.logsNetwork/logsCache/logsNativeChat/logsMarkdown` property names match between Tasks 3, 4
- `AppLogger.shared.clear()` / `setEnabled(_, _)` / `entries` — same names in Tasks 2, 4, 5–8

**Known deviations from spec (intentional):**
1. Spec §9 says "保留 `SMAlog:` 前缀" at call sites; this plan strips prefixes at call sites and re-adds in `AppLogger`. Net effect on Console grep is unchanged (and improved — SessionManager's `log:` prefix is normalized to `SMAlog:`).
2. Spec §6 used `MainActor.assumeIsolated` for OSLog access. Plan notes a fallback (top-level `let osLogs`) if compiler rejects.
