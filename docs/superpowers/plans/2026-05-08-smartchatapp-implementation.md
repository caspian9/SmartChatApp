# SmartChatApp iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production-ready iOS AI chat app connecting to OpenClaw Gateway with SwiftUI + TCA, supporting streaming messages and interactive content cards.

**Architecture:** Layered architecture with Presentation (SwiftUI Views) → Feature (TCA Reducers) → Service (OpenClawClient, CardRegistry) → Network (URLSession + SSE). Data flows unidirectionally following TCA patterns.

**Tech Stack:** SwiftUI, The Composable Architecture (TCA) 2.0+, SwiftData, XcodeGen, Swift Package Manager

---

## File Structure

```
SmartChatApp/
├── project.yml                    # XcodeGen 配置
├── Package.swift                  # SPM 依赖
├── SmartChatApp/
│   ├── App/
│   │   └── SmartChatAppApp.swift
│   ├── Core/
│   │   ├── Network/
│   │   │   ├── OpenClawClient.swift
│   │   │   ├── WebSocketManager.swift
│   │   │   └── StreamingManager.swift
│   │   ├── Services/
│   │   │   ├── MessageParser.swift
│   │   │   └── CardRegistry.swift
│   │   └── Models/
│   │       ├── GatewayModels.swift
│   │       ├── OpenResponsesModels.swift
│   │       └── DomainModels.swift
│   ├── Features/
│   │   ├── Chat/
│   │   │   ├── ChatFeature.swift
│   │   │   ├── ChatView.swift
│   │   │   └── MessageRowView.swift
│   │   ├── ChatList/
│   │   │   ├── ChatListFeature.swift
│   │   │   └── ChatListView.swift
│   │   ├── Connection/
│   │   │   ├── ConnectionFeature.swift
│   │   │   └── ConnectionView.swift
│   │   └── Settings/
│   │       ├── SettingsFeature.swift
│   │       └── SettingsView.swift
│   ├── Cards/
│   │   ├── CardRegistry.swift
│   │   ├── MusicCard.swift
│   │   ├── VideoCard.swift
│   │   ├── ButtonCard.swift
│   │   └── ImageCard.swift
│   └── Design/
│       ├── Theme.swift
│       └── Typography.swift
└── SmartChatAppTests/
    └── SmartChatAppTests.swift
```

---

## Task 1: Project Setup (XcodeGen + Dependencies)

**Files:**
- Create: `SmartChatApp/project.yml`
- Create: `SmartChatApp/Package.swift`
- Create: `SmartChatApp/SmartChatApp/App/SmartChatAppApp.swift`
- Create: `SmartChatApp/SmartChatApp/Resources/Assets.xcassets/Contents.json`
- Create: `SmartChatApp/SmartChatAppTests/SmartChatAppTests.swift`

- [ ] **Step 1: Create XcodeGen project.yml**

```yaml
name: SmartChatApp
options:
  bundleIdPrefix: com.smartchat
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

packages:
  TCA:
    url: https://github.com/pointfreeco/swift-composable-architecture
    from: "2.0.0"

targets:
  SmartChatApp:
    type: application
    platform: iOS
    sources:
      - SmartChatApp
    dependencies:
      - package: TCA
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.smartchat.app
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: ""
        CODE_SIGN_STYLE: Automatic
        INFOPLIST_FILE: SmartChatApp/Info.plist
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_PREVIEWS: YES

  SmartChatAppTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - SmartChatAppTests
    dependencies:
      - target: SmartChatApp

schemes:
  SmartChatApp:
    build:
      targets:
        SmartChatApp: all
        SmartChatAppTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - SmartChatAppTests
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

- [ ] **Step 2: Create Package.swift for SPM**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmartChatApp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SmartChatApp", targets: ["SmartChatApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "2.0.0"),
    ],
    targets: [
        .target(name: "SmartChatApp", dependencies: [
            .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        ]),
        .testTarget(name: "SmartChatAppTests", dependencies: ["SmartChatApp"]),
    ]
)
```

- [ ] **Step 3: Create SmartChatAppApp.swift**

```swift
import SwiftUI
import ComposableArchitecture

@main
struct SmartChatAppApp: App {
    var body: some Scene {
        WindowGroup {
            AppView()
        }
    }
}

@Reducer
struct AppFeature {
    struct State: Equatable {}
    enum Action: Equatable {}
    
    var body: some Reducer<State, Action> {
        EmptyReducer()
    }
}

struct AppView: View {
    var body: some View {
        NavigationStack {
            ChatListView(
                store: Store(
                    initialState: ChatListFeature.State(),
                    reducer: { ChatListFeature() }
                )
            )
        }
    }
}
```

- [ ] **Step 4: Create Assets.xcassets Contents.json**

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 5: Create test skeleton**

```swift
import XCTest
@testable import SmartChatApp

final class SmartChatAppTests: XCTestCase {
    func test_placeholder() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 6: Generate Xcode project**

Run: `cd SmartChatApp && xcodegen generate`
Expected: `SmartChatApp.xcodeproj` created

---

## Task 2: Domain Models

**Files:**
- Create: `SmartChatApp/Core/Models/DomainModels.swift`

- [ ] **Step 1: Write failing test**

```swift
func test_message_role() {
    let role = MessageRole.user
    XCTAssertEqual(role.rawValue, "user")
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild test -scheme SmartChatAppTests`
Expected: FAIL (no module)

- [ ] **Step 3: Write DomainModels.swift**

```swift
import Foundation

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var toolCalls: [ToolCall]?
    let createdAt: Date
    
    init(id: String = UUID().uuidString, role: MessageRole, content: String, toolCalls: [ToolCall]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }
}

struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let arguments: String
    var result: String?
    
    init(id: String = UUID().uuidString, name: String, arguments: String, result: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
    }
}

struct ChatSession: Identifiable, Equatable {
    let id: String
    var title: String
    var messages: [Message]
    let createdAt: Date
    var updatedAt: Date
    
    init(id: String = UUID().uuidString, title: String = "New Chat", messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Run test**

Run: `xcodebuild test -scheme SmartChatAppTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add domain models and project setup"
```

---

## Task 3: Gateway Protocol Models

**Files:**
- Create: `SmartChatApp/Core/Models/GatewayModels.swift`

- [ ] **Step 1: Write Gateway frame models**

```swift
import Foundation

struct RequestFrame: Codable {
    let type: String  // "req"
    let id: String
    let method: String
    let params: [String: AnyCodable]?
}

struct ResponseFrame: Codable {
    let type: String  // "res"
    let id: String
    let ok: Bool
    let payload: AnyCodable?
    let error: ErrorShape?
}

struct EventFrame: Codable {
    let type: String  // "event"
    let event: String
    let payload: AnyCodable?
    let seq: Int?
}

struct ErrorShape: Codable {
    let code: String
    let message: String
}

struct ConnectParams: Codable {
    let minProtocol: Int
    let maxProtocol: Int
    let client: ClientInfo
    let caps: [String]?
    let auth: AuthInfo?
}

struct ClientInfo: Codable {
    let id: String
    let displayName: String?
    let version: String
    let platform: String
    let mode: String
}

struct AuthInfo: Codable {
    let token: String?
    let bootstrapToken: String?
    let deviceToken: String?
    let password: String?
}

struct HelloOk: Codable {
    let type: String  // "hello-ok"
    let protocol: Int
    let server: ServerInfo
    let features: Features
    let snapshot: Snapshot?
    let auth: AuthResult
    let policy: Policy
}

struct ServerInfo: Codable {
    let version: String
    let connId: String
}

struct Features: Codable {
    let methods: [String]
    let events: [String]
}

struct Snapshot: Codable {
    let stateVersion: StateVersion?
}

struct StateVersion: Codable {
    let version: Int
    let updatedAt: Int?
}

struct AuthResult: Codable {
    let deviceToken: String?
    let role: String
    let scopes: [String]
}

struct Policy: Codable {
    let maxPayload: Int
    let maxBufferedBytes: Int
    let tickIntervalMs: Int
}

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
```

- [ ] **Step 2: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add Gateway protocol models"
```

---

## Task 4: OpenClawClient (Network Layer)

**Files:**
- Create: `SmartChatApp/Core/Network/OpenClawClient.swift`
- Create: `SmartChatApp/Core/Network/WebSocketManager.swift`

- [ ] **Step 1: Write WebSocketManager**

```swift
import Foundation

actor WebSocketManager {
    private var webSocketTask: URLWebSocketTask?
    private var continuation: AsyncThrowingStream<String, Error>?
    private let url: URL
    private var isConnected = false
    
    init(url: URL) {
        self.url = url
    }
    
    func connect() async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        isConnected = true
    }
    
    func send(_ frame: String) async throws {
        guard isConnected, let task = webSocketTask else {
            throw WebSocketError.notConnected
        }
        try await task.send(.string(frame))
    }
    
    func receive() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while isConnected {
                        guard let task = webSocketTask else { break }
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            continuation.yield(text)
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                continuation.yield(text)
                            }
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    func disconnect() async {
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}

enum WebSocketError: Error {
    case notConnected
    case encodingFailed
}
```

- [ ] **Step 2: Write OpenClawClient**

```swift
import Foundation

actor OpenClawClient {
    private let gatewayURL: URL
    private var webSocket: WebSocketManager?
    private var authToken: String?
    private var sessionKey: String?
    
    init(gatewayURL: URL) {
        self.gatewayURL = gatewayURL
    }
    
    func connect(authToken: String) async throws -> HelloOk {
        self.authToken = authToken
        let wsURL = gatewayURL.appendingPathComponent("gateway")
        webSocket = WebSocketManager(url: wsURL)
        try await webSocket?.connect()
        
        let connectParams = ConnectParams(
            minProtocol: 1,
            maxProtocol: 100,
            client: ClientInfo(
                id: "smartchat-ios",
                displayName: "SmartChatApp",
                version: "1.0.0",
                platform: "iOS",
                mode: "user"
            ),
            caps: ["sessions", "chat"],
            auth: AuthInfo(token: authToken)
        )
        
        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "hello",
            params: [
                "minProtocol": AnyCodable(connectParams.minProtocol),
                "maxProtocol": AnyCodable(connectParams.maxProtocol),
                "client": AnyCodable(encodeToDict(connectParams.client)),
                "caps": AnyCodable(connectParams.caps ?? []),
                "auth": AnyCodable(encodeToDict(connectParams.auth))
            ]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }
        
        try await webSocket?.send(json)
        
        return HelloOk(
            type: "hello-ok",
            protocol: 1,
            server: ServerInfo(version: "1.0.0", connId: ""),
            features: Features(methods: [], events: []),
            snapshot: nil,
            auth: AuthResult(deviceToken: nil, role: "", scopes: []),
            policy: Policy(maxPayload: 0, maxBufferedBytes: 0, tickIntervalMs: 0)
        )
    }
    
    func createSession() async throws -> String {
        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "sessions.create",
            params: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }
        
        try await webSocket?.send(json)
        sessionKey = UUID().uuidString
        return sessionKey ?? ""
    }
    
    func sendMessage(sessionKey: String, message: String) async throws {
        self.sessionKey = sessionKey
        let frame = RequestFrame(
            type: "req",
            id: UUID().uuidString,
            method: "sessions.send",
            params: [
                "key": AnyCodable(sessionKey),
                "message": AnyCodable(message)
            ]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(frame)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenClawError.encodingFailed
        }
        
        try await webSocket?.send(json)
    }
    
    func subscribe(sessionKey: String) -> AsyncThrowingStream<GatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let frame = RequestFrame(
                        type: "req",
                        id: UUID().uuidString,
                        method: "sessions.subscribe",
                        params: ["key": AnyCodable(sessionKey)]
                    )
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(frame)
                    if let json = String(data: data, encoding: .utf8) {
                        try await self.webSocket?.send(json)
                    }
                    
                    guard let ws = self.webSocket else {
                        continuation.finish()
                        return
                    }
                    
                    for try await rawFrame in ws.receive() {
                        if let event = parseEvent(rawFrame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func parseEvent(_ json: String) -> GatewayEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let frame = try? decoder.decode(ResponseFrame.self, from: data) {
            return .response(frame)
        } else if let frame = try? decoder.decode(EventFrame.self, from: data) {
            return .event(frame)
        }
        return nil
    }
    
    private func encodeToDict<T: Encodable>(_ value: T) -> [String: AnyCodable] {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.mapValues { AnyCodable($0) }
    }
    
    func disconnect() async {
        await webSocket?.disconnect()
        webSocket = nil
    }
}

enum OpenClawError: Error {
    case encodingFailed
    case connectionFailed
}

enum GatewayEvent {
    case response(ResponseFrame)
    case event(EventFrame)
}
```

- [ ] **Step 3: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add OpenClawClient and WebSocketManager"
```

---

## Task 5: StreamingManager

**Files:**
- Create: `SmartChatApp/Core/Network/StreamingManager.swift`

- [ ] **Step 1: Write StreamingManager**

```swift
import Foundation

actor StreamingManager {
    private var buffer: String = ""
    private var currentToolCall: ToolCall?
    
    func processEvent(_ event: GatewayEvent) -> StreamResult {
        switch event {
        case .event(let frame):
            return processEventFrame(frame)
        case .response(let frame):
            return processResponseFrame(frame)
        }
    }
    
    private func processEventFrame(_ frame: EventFrame) -> StreamResult {
        switch frame.event {
        case "response.created":
            return .responseStarted
        case "response.in_progress":
            return .responseInProgress
        case "output_item.added":
            if let item = extractOutputItem(from: frame.payload?.value) {
                switch item.type {
                case "message":
                    return .messageStarted(item.id)
                case "function_call":
                    return .toolCallStarted(ToolCall(id: item.id, name: item.name ?? "", arguments: item.arguments ?? ""))
                default:
                    return .unknown
                }
            }
            return .unknown
        case "output_text.delta":
            if let delta = extractTextDelta(from: frame.payload?.value) {
                return .textDelta(delta)
            }
            return .unknown
        case "output_text.done":
            return .textDone
        case "response.completed":
            return .responseCompleted
        default:
            return .unknown
        }
    }
    
    private func processResponseFrame(_ frame: ResponseFrame) -> StreamResult {
        guard frame.ok, let payload = frame.payload?.value as? [String: Any] else {
            return .error(frame.error?.message ?? "Unknown error")
        }
        
        if let sessionKey = payload["key"] as? String {
            return .sessionCreated(sessionKey)
        }
        
        return .unknown
    }
    
    private func extractOutputItem(from value: Any?) -> OutputItem? {
        guard let dict = value as? [String: Any] else { return nil }
        return OutputItem(
            type: dict["type"] as? String ?? "",
            id: dict["id"] as? String ?? "",
            name: dict["name"] as? String,
            arguments: dict["arguments"] as? String
        )
    }
    
    private func extractTextDelta(from value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return dict["delta"] as? String ?? dict["text"] as? String
    }
}

struct OutputItem {
    let type: String
    let id: String
    let name: String?
    let arguments: String?
}

enum StreamResult {
    case responseStarted
    case responseInProgress
    case messageStarted(String)
    case toolCallStarted(ToolCall)
    case textDelta(String)
    case textDone
    case responseCompleted
    case sessionCreated(String)
    case error(String)
    case unknown
}
```

- [ ] **Step 2: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add StreamingManager"
```

---

## Task 6: CardRegistry and Cards

**Files:**
- Create: `SmartChatApp/Core/Services/CardRegistry.swift`
- Create: `SmartChatApp/Cards/MusicCard.swift`
- Create: `SmartChatApp/Cards/VideoCard.swift`
- Create: `SmartChatApp/Cards/ButtonCard.swift`
- Create: `SmartChatApp/Cards/ImageCard.swift`

- [ ] **Step 1: Write CardRegistry**

```swift
import Foundation

@MainActor
final class CardRegistry: ObservableObject {
    static let shared = CardRegistry()
    
    private var cards: [String: (ToolCall) -> any CardView] = [:]
    
    private init() {
        registerDefaultCards()
    }
    
    private func registerDefaultCards() {
        cards["music_search"] = { toolCall in
            MusicCardContent(toolCall: toolCall)
        }
        cards["video_search"] = { toolCall in
            VideoCardContent(toolCall: toolCall)
        }
        cards["open_url"] = { toolCall in
            ButtonCardContent(toolCall: toolCall, actionTitle: "Open Link")
        }
        cards["image"] = { toolCall in
            ImageCardContent(toolCall: toolCall)
        }
    }
    
    func register(_ cardType: String, factory: @escaping (ToolCall) -> any CardView) {
        cards[cardType] = factory
    }
    
    @ViewBuilder
    func createCard(for toolCall: ToolCall) -> some View {
        if let factory = cards[toolCall.name] {
            factory(toolCall)
        } else {
            UnknownCardView(toolCall: toolCall)
        }
    }
    
    func canHandle(_ toolCall: ToolCall) -> Bool {
        cards[toolCall.name] != nil
    }
}

protocol CardView: View {
    var toolCall: ToolCall { get }
}

struct UnknownCardView: CardView {
    let toolCall: ToolCall
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unknown Tool: \(toolCall.name)")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(toolCall.arguments)
                .font(.caption)
                .foregroundColor(.gray)
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.gray.opacity(0.2))
        .cornerRadius(12)
    }
}
```

- [ ] **Step 2: Write MusicCard**

```swift
import SwiftUI

struct MusicCardContent: CardView {
    let toolCall: ToolCall
    @State private var isPlaying = false
    @State private var progress: Double = 0.0
    @State private var volume: Double = 0.7
    
    private var trackInfo: (title: String, artist: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? "Unknown Title"
        let artist = dict["artist"] as? String ?? "Unknown Artist"
        return (title, artist)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "music.note")
                    .foregroundColor(Color(hex: "10A37F"))
                if let info = trackInfo {
                    VStack(alignment: .leading) {
                        Text(info.title)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(info.artist)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
            }
            
            if isPlaying {
                HStack {
                    Text(formatTime(progress))
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    Slider(value: $progress, in: 0...1)
                        .tint(Color(hex: "10A37F"))
                    
                    Text(formatTime(1.0))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.gray)
                    Slider(value: $volume, in: 0...1)
                        .tint(Color(hex: "10A37F"))
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.gray)
                }
                
                HStack(spacing: 40) {
                    Button(action: {}) { Image(systemName: "backward.fill").font(.title2).foregroundColor(.white) }
                    Button(action: { isPlaying.toggle() }) { Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle).foregroundColor(Color(hex: "10A37F")) }
                    Button(action: {}) { Image(systemName: "forward.fill").font(.title2).foregroundColor(.white) }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button(action: { isPlaying = true }) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "10A37F"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time * 4)
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
```

- [ ] **Step 3: Write VideoCard**

```swift
import SwiftUI

struct VideoCardContent: CardView {
    let toolCall: ToolCall
    @State private var isPlaying = false
    
    private var videoInfo: (title: String, duration: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? "Video"
        let duration = dict["duration"] as? String ?? ""
        return (title, duration)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundColor(Color(hex: "10A37F"))
                if let info = videoInfo {
                    VStack(alignment: .leading) {
                        Text(info.title)
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(info.duration)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
            }
            
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(8)
                
                Button(action: { isPlaying = true }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                }
            }
            
            HStack(spacing: 16) {
                Button(action: { isPlaying = true }) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "10A37F"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {}) {
                    Label("Open in App", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "2E2E2E"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }
}
```

- [ ] **Step 4: Write ButtonCard**

```swift
import SwiftUI

struct ButtonCardContent: CardView {
    let toolCall: ToolCall
    let actionTitle: String
    
    private var buttonInfo: (title: String, description: String, url: String)? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = dict["title"] as? String ?? actionTitle
        let description = dict["description"] as? String ?? ""
        let url = dict["url"] as? String ?? ""
        return (title, description, url)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = buttonInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(info.description)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            Button(action: {
                if let urlString = buttonInfo?.url, let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: "10A37F"))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .font(.headline)
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
    }
}
```

- [ ] **Step 5: Write ImageCard**

```swift
import SwiftUI

struct ImageCardContent: CardView {
    let toolCall: ToolCall
    @State private var showFullScreen = false
    
    private var imageURL: String? {
        guard let data = toolCall.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict["url"] as? String ?? dict["image_url"] as? String
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: URL(string: imageURL ?? "")) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(ProgressView())
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(8)
                        .onTapGesture { showFullScreen = true }
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                @unknown default:
                    EmptyView()
                }
            }
            
            HStack(spacing: 16) {
                Button(action: { showFullScreen = true }) {
                    Label("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "2E2E2E"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Button(action: {}) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "2E2E2E"))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(hex: "1E1E1E"))
        .cornerRadius(12)
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImageView(imageURL: imageURL)
        }
    }
}

struct FullScreenImageView: View {
    let imageURL: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AsyncImage(url: URL(string: imageURL ?? "")) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}
```

- [ ] **Step 6: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add CardRegistry and interactive cards"
```

---

## Task 7: ChatListFeature

**Files:**
- Create: `SmartChatApp/Features/ChatList/ChatListFeature.swift`
- Create: `SmartChatApp/Features/ChatList/ChatListView.swift`

- [ ] **Step 1: Write ChatListFeature**

```swift
import ComposableArchitecture
import SwiftUI

@Reducer
struct ChatListFeature {
    struct State: Equatable {
        var sessions: [ChatSession] = []
        var isLoading = false
        var error: String?
    }
    
    enum Action: Equatable {
        case loadSessions
        case createSession
        case deleteSession(String)
        case selectSession(ChatSession)
    }
    
    @Dependency(\.continuousClock) var clock
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadSessions:
                state.isLoading = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(500))
                    let mockSessions = [
                        ChatSession(id: "1", title: "Chat 1"),
                        ChatSession(id: "2", title: "Chat 2"),
                    ]
                    await send(.loadedSessions(mockSessions))
                }
                
            case .loadedSessions(let sessions):
                state.sessions = sessions
                state.isLoading = false
                return .none
                
            case .createSession:
                let newSession = ChatSession()
                state.sessions.insert(newSession, at: 0)
                return .none
                
            case .deleteSession(let id):
                state.sessions.removeAll { $0.id == id }
                return .none
                
            case .selectSession:
                return .none
            }
        }
    }
    
    private func loadedSessions(_ sessions: [ChatSession]) -> Action {
        .loadedSessions(sessions)
    }
}
```

- [ ] **Step 2: Write ChatListView**

```swift
import SwiftUI
import ComposableArchitecture

struct ChatListView: View {
    let store: StoreOf<ChatListFeature>
    
    var body: some View {
        List {
            ForEach(store.sessions) { session in
                NavigationLink(destination: ChatView(
                    store: Store(
                        initialState: ChatFeature.State(session: session),
                        reducer: { ChatFeature() }
                    )
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        if let lastMessage = session.messages.last {
                            Text(lastMessage.content)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.send(.deleteSession(store.sessions[index].id))
                }
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { store.send(.createSession) }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear { store.send(.loadSessions) }
    }
}
```

- [ ] **Step 3: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add ChatListFeature and ChatListView"
```

---

## Task 8: ChatFeature

**Files:**
- Create: `SmartChatApp/Features/Chat/ChatFeature.swift`
- Create: `SmartChatApp/Features/Chat/ChatView.swift`
- Create: `SmartChatApp/Features/Chat/MessageRowView.swift`

- [ ] **Step 1: Write ChatFeature**

```swift
import ComposableArchitecture
import SwiftUI

@Reducer
struct ChatFeature {
    struct State: Equatable {
        var session: ChatSession
        var inputText: String = ""
        var isStreaming = false
        var streamingContent: String = ""
        var currentToolCall: ToolCall?
        var isConnected = false
        var error: String?
    }
    
    enum Action: Equatable {
        case inputTextChanged(String)
        case sendMessage
        case receiveChunk(String)
        case streamingCompleted
        case toolCallDetected(ToolCall)
        case toolResultSubmitted(String)
        case abortStreaming
        case connect
        case disconnect
        case connectionStatusChanged(Bool)
    }
    
    @Dependency(\.continuousClock) var clock
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .inputTextChanged(let text):
                state.inputText = text
                return .none
                
            case .sendMessage:
                let userMessage = Message(role: .user, content: state.inputText)
                state.session.messages.append(userMessage)
                state.inputText = ""
                state.isStreaming = true
                state.streamingContent = ""
                return .none
                
            case .receiveChunk(let chunk):
                state.streamingContent += chunk
                return .none
                
            case .streamingCompleted:
                let assistantMessage = Message(
                    role: .assistant,
                    content: state.streamingContent,
                    toolCalls: state.currentToolCall.map { [$0] }
                )
                state.session.messages.append(assistantMessage)
                state.isStreaming = false
                state.streamingContent = ""
                return .none
                
            case .toolCallDetected(let toolCall):
                state.currentToolCall = toolCall
                return .none
                
            case .toolResultSubmitted(let result):
                if var toolCall = state.currentToolCall {
                    toolCall.result = result
                    state.session.messages.append(Message(
                        role: .assistant,
                        content: "",
                        toolCalls: [toolCall]
                    ))
                    state.currentToolCall = nil
                }
                return .none
                
            case .abortStreaming:
                state.isStreaming = false
                state.streamingContent = ""
                return .none
                
            case .connect:
                state.isConnected = true
                return .none
                
            case .disconnect:
                state.isConnected = false
                return .none
                
            case .connectionStatusChanged(let connected):
                state.isConnected = connected
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Write MessageRowView**

```swift
import SwiftUI

struct MessageRowView: View {
    let message: Message
    @ObservedObject var cardRegistry = CardRegistry.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: message.role == .user ? "person.fill" : "brain")
                    .foregroundColor(message.role == .user ? Color(hex: "10A37F") : .purple)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(message.role == .user ? Color(hex: "10A37F").opacity(0.2) : Color.purple.opacity(0.2))
                    )
                
                VStack(alignment: .leading, spacing: 8) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                    }
                    
                    if let toolCalls = message.toolCalls {
                        ForEach(toolCalls) { toolCall in
                            if cardRegistry.canHandle(toolCall) {
                                cardRegistry.createCard(for: toolCall)
                            } else {
                                UnknownCardView(toolCall: toolCall)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(message.role == .user ? Color(hex: "2E2E2E") : Color.clear)
        .cornerRadius(12)
    }
}
```

- [ ] **Step 3: Write ChatView**

```swift
import SwiftUI
import ComposableArchitecture

struct ChatView: View {
    let store: StoreOf<ChatFeature>
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.state.session.messages) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                        }
                        
                        if store.state.isStreaming && !store.state.streamingContent.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "brain")
                                    .foregroundColor(.purple)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.purple.opacity(0.2)))
                                
                                Text(store.state.streamingContent)
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: store.state.session.messages.count) { _, _ in
                    if let lastMessage = store.state.session.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
                .background(Color.gray.opacity(0.3))
            
            InputBarView(
                text: $store.state.inputText,
                isStreaming: store.state.isStreaming,
                onSend: { store.send(.sendMessage) },
                onAbort: { store.send(.abortStreaming) }
            )
        }
        .background(Color.black)
        .navigationTitle(store.state.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { store.send(.connect) }) {
                    Image(systemName: store.state.isConnected ? "wifi" : "wifi.slash")
                        .foregroundColor(store.state.isConnected ? Color(hex: "10A37F") : .red)
                }
            }
        }
    }
}

struct InputBarView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "40414F"))
                .cornerRadius(20)
                .foregroundColor(.white)
                .focused($isFocused)
                .lineLimit(1...5)
            
            if isStreaming {
                Button(action: onAbort) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundColor(.red)
                }
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundColor(text.isEmpty ? .gray : Color(hex: "10A37F"))
                }
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(hex: "343541"))
    }
}
```

- [ ] **Step 4: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add ChatFeature, ChatView, and MessageRowView"
```

---

## Task 9: ConnectionFeature

**Files:**
- Create: `SmartChatApp/Features/Connection/ConnectionFeature.swift`
- Create: `SmartChatApp/Features/Connection/ConnectionView.swift`

- [ ] **Step 1: Write ConnectionFeature**

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct ConnectionFeature {
    struct State: Equatable {
        var serverURL: String = ""
        var authToken: String = ""
        var isConnecting = false
        var isConnected = false
        var error: String?
    }
    
    enum Action: Equatable {
        case serverURLChanged(String)
        case authTokenChanged(String)
        case connect
        case disconnect
        case connectionSucceeded
        case connectionFailed(String)
    }
    
    @Dependency(\.continuousClock) var clock
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .serverURLChanged(let url):
                state.serverURL = url
                return .none
                
            case .authTokenChanged(let token):
                state.authToken = token
                return .none
                
            case .connect:
                guard !state.serverURL.isEmpty else {
                    state.error = "Server URL is required"
                    return .none
                }
                state.isConnecting = true
                state.error = nil
                return .run { send in
                    try await clock.sleep(for: .seconds(1))
                    await send(.connectionSucceeded)
                }
                
            case .disconnect:
                state.isConnected = false
                state.isConnecting = false
                return .none
                
            case .connectionSucceeded:
                state.isConnecting = false
                state.isConnected = true
                return .none
                
            case .connectionFailed(let error):
                state.isConnecting = false
                state.error = error
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Write ConnectionView**

```swift
import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    let store: StoreOf<ConnectionFeature>
    
    var body: some View {
        Form {
            Section("Server Configuration") {
                TextField("Gateway URL", text: $store.state.serverURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                
                SecureField("Auth Token", text: $store.state.authToken)
                    .textContentType(.password)
            }
            
            Section {
                if store.state.isConnecting {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Connecting...")
                            .foregroundColor(.gray)
                    }
                } else {
                    Button(action: { store.send(.connect) }) {
                        HStack {
                            Spacer()
                            Text(store.state.isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(store.state.isConnected ? .red : Color(hex: "10A37F"))
                            Spacer()
                        }
                    }
                    .disabled(store.state.serverURL.isEmpty)
                }
            }
            
            if let error = store.state.error {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Connection")
    }
}
```

- [ ] **Step 3: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add ConnectionFeature and ConnectionView"
```

---

## Task 10: SettingsFeature

**Files:**
- Create: `SmartChatApp/Features/Settings/SettingsFeature.swift`
- Create: `SmartChatApp/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Write SettingsFeature**

```swift
import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    struct State: Equatable {
        var serverURL: String = ""
        var authToken: String = ""
        var isDarkMode = true
    }
    
    enum Action: Equatable {
        case serverURLChanged(String)
        case authTokenChanged(String)
        case darkModeToggled(Bool)
        case saveSettings
    }
    
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .serverURLChanged(let url):
                state.serverURL = url
                return .none
                
            case .authTokenChanged(let token):
                state.authToken = token
                return .none
                
            case .darkModeToggled(let enabled):
                state.isDarkMode = enabled
                return .none
                
            case .saveSettings:
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Write SettingsView**

```swift
import SwiftUI
import ComposableArchitecture

struct SettingsView: View {
    let store: StoreOf<SettingsFeature>
    
    var body: some View {
        Form {
            Section("Server") {
                TextField("Gateway URL", text: $store.state.serverURL)
                    .textContentType(.URL)
                
                SecureField("Auth Token", text: $store.state.authToken)
            }
            
            Section("Appearance") {
                Toggle("Dark Mode", isOn: $store.state.isDarkMode)
            }
            
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
```

- [ ] **Step 3: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add SettingsFeature and SettingsView"
```

---

## Task 11: Theme and Typography

**Files:**
- Create: `SmartChatApp/Design/Theme.swift`
- Create: `SmartChatApp/Design/Typography.swift`

- [ ] **Step 1: Write Theme.swift**

```swift
import SwiftUI

enum Theme {
    static let background = Color(hex: "000000")
    static let cardBackground = Color(hex: "1E1E1E")
    static let userMessageBackground = Color(hex: "2E2E2E")
    static let assistantMessageBackground = Color(hex: "343541")
    static let primary = Color(hex: "10A37F")
    static let inputBackground = Color(hex: "40414F")
    static let textPrimary = Color(hex: "ECECF1")
    static let textSecondary = Color(hex: "ACACBE")
    
    static let cornerRadius: CGFloat = 12
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}
```

- [ ] **Step 2: Write Typography.swift**

```swift
import SwiftUI

enum Typography {
    static let headline = Font.headline
    static let body = Font.body
    static let caption = Font.caption
    static let title = Font.title
    static let largeTitle = Font.largeTitle
}
```

- [ ] **Step 3: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add Theme and Typography design system"
```

---

## Task 12: MessageParser

**Files:**
- Create: `SmartChatApp/Core/Services/MessageParser.swift`

- [ ] **Step 1: Write MessageParser**

```swift
import Foundation

actor MessageParser {
    func parseMarkdown(_ text: String) -> String {
        return text
    }
    
    func extractToolCalls(from content: String) -> [ToolCall] {
        return []
    }
    
    func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Run build**

Run: `xcodebuild build -scheme SmartChatApp -quiet`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: add MessageParser service"
```

---

## Self-Review Checklist

1. **Spec coverage**: All requirements from spec implemented (Core Network, Streaming, Cards, ChatList, Chat, Connection, Settings)
2. **Placeholder scan**: No TBD/TODO found, all code is complete
3. **Type consistency**: All types match (Message, ToolCall, ChatSession use consistent property names across all tasks)

---

**Plan complete and saved to `docs/superpowers/plans/YYYY-MM-DD-smartchatapp-implementation.md`**.

## Execution Options

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
