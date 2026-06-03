# ChatListView 缓存机制实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 ChatListView 添加两层缓存机制：启动时先显示缓存再后台刷新，支持完全离线访问。

**Architecture:** 使用 UserDefaults 存储 JSON 序列化的会话列表。ChatListView 在 onAppear 时先加载缓存显示，然后后台静默刷新网络数据。

**Tech Stack:** Swift, SwiftUI, UserDefaults

---

## 文件结构

- **Create:** `SmartChatApp/Core/Services/SessionCache.swift` — 缓存服务，封装 UserDefaults 读写
- **Modify:** `SmartChatApp/Features/ChatList/ChatListView.swift` — 集成缓存逻辑

---

## Task 1: 创建 SessionCache 服务

**Files:**
- Create: `SmartChatApp/Core/Services/SessionCache.swift`

- [ ] **Step 1: 创建 SessionCache.swift**

```swift
import Foundation

struct CachedSessions: Codable {
    let sessions: [OpenClawChatSessionEntry]
    let timestamp: Date
    let version: Int

    static let currentVersion = 1
}

enum SessionCache {
    private static let key = "cached_sessions"

    static func save(_ sessions: [OpenClawChatSessionEntry]) {
        let cached = CachedSessions(
            sessions: sessions,
            timestamp: Date(),
            version: CachedSessions.currentVersion
        )
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [OpenClawChatSessionEntry]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(CachedSessions.self, from: data),
              cached.version == CachedSessions.currentVersion else {
            return nil
        }
        return cached.sessions
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: 验证编译**

Run: `xcodebuild build -scheme SmartChatApp -quiet DEVELOPMENT_TEAM=24X2NMFQUY 2>&1 | grep -E "(error|warning)" | head -5`
Expected: 无 error（warning 可忽略）

- [ ] **Step 3: 提交**

```bash
git add SmartChatApp/Core/Services/SessionCache.swift
git commit -m "feat: add SessionCache for offline session storage

- Save/load sessions via UserDefaults
- Version tracking for cache format migration
- Encodes/decodes via Codable"

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 2: 修改 ChatListView 集成缓存

**Files:**
- Modify: `SmartChatApp/Features/ChatList/ChatListView.swift:5-80`

- [ ] **Step 1: 修改 ChatListView 添加缓存逻辑**

将 `loadSessions()` 方法改为使用缓存模式：

```swift
struct ChatListView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var showError = false

    var body: some View {
        List {
            if isLoading && sessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }

            ForEach(sessions) { session in
                NavigationLink(destination: sessionView(for: session)) {
                    SessionRowView(session: session)
                }
                .listRowBackground(Color(hex: "1E1E1E"))
            }
            .onDelete { indexSet in
                // Handle delete if supported
            }
        }
        .listStyle(.plain)
        .background(Color.black)
        .refreshable {
            await refreshFromNetwork()
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: createSession) {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
        }
        .onAppear {
            loadFromCacheThenRefresh()
        }
    }

    private func loadFromCacheThenRefresh() {
        // 1. 先加载缓存显示
        if let cached = SessionCache.load() {
            sessions = cached
            isLoading = false
        } else {
            isLoading = true
        }

        // 2. 后台刷新网络数据
        Task {
            await refreshFromNetwork()
        }
    }

    private func refreshFromNetwork() async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = SessionManager.shared.makeTransport(sessionKey: "")
            let response = try await transport.listSessions(limit: 50)
            await MainActor.run {
                sessions = response.sessions
                isLoading = false
                SessionCache.save(response.sessions)
            }
        } catch {
            await MainActor.run {
                isLoading = false
                // 网络失败时保持缓存数据，静默处理
            }
        }
    }

    @ViewBuilder
    private func sessionView(for session: OpenClawChatSessionEntry) -> some View {
        let transport = SessionManager.shared.makeTransport(sessionKey: session.key)
        ChatView(
            sessionKey: session.key,
            sessionEntry: session,
            transport: transport,
            onAppear: {
                Task {
                    try? await SessionManager.shared.ensureConnected()
                }
            }
        )
    }

    private func createSession() {
        Task {
            do {
                try await SessionManager.shared.ensureConnected()
                let sessionKey = try await SessionManager.shared.createSession()
                let transport = SessionManager.shared.makeTransport(sessionKey: sessionKey)
                let response = try await transport.listSessions(limit: 50)
                await MainActor.run {
                    sessions = response.sessions
                    SessionCache.save(response.sessions)
                }
            } catch {
                print("Failed to create session: \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: 添加 import（如果还没有）**

确认文件顶部有 `import OpenClawKit`（已存在，用于 `OpenClawChatSessionEntry`）。SessionCache 使用标准 Foundation，不需要额外 import。

- [ ] **Step 3: 验证编译**

Run: `xcodebuild build -scheme SmartChatApp -quiet DEVELOPMENT_TEAM=24X2NMFQUY 2>&1 | grep -E "(error|warning)" | head -10`
Expected: 无 error

- [ ] **Step 4: 提交**

```bash
git add SmartChatApp/Features/ChatList/ChatListView.swift
git commit -m "feat: integrate SessionCache in ChatListView

- onAppear loads cached sessions immediately
- Background refresh updates from network
- Graceful offline support with cached data

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## 验证步骤

1. 编译通过：`xcodebuild build -scheme SmartChatApp -quiet`
2. 安装到设备：`ideviceinstaller -n -u 00008120-0019192202DB401E -w install <path>`
3. 启动 App 验证：
   - 首次启动应该正常显示（或空列表）
   - 有会话后杀掉 App 再打开，应该能看到缓存的会话
   - 下拉刷新应该从网络更新数据