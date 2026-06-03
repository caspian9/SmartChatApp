# ChatListView 缓存机制设计

## 目标

- 启动时先用缓存显示，后台静默刷新
- 完全离线时也能显示缓存数据

## 架构

```
ChatListView
    ├── onAppear
    │   ├── loadFromCache() → 立即显示
    │   └── Task { refreshFromNetwork() } → 后台更新
    └── refreshable
        └── refreshFromNetwork() → 更新并写缓存
```

## 组件设计

### 1. SessionCache 服务

```swift
// 文件: SmartChatApp/Core/Services/SessionCache.swift
struct CachedSessions: Codable {
    let sessions: [OpenClawChatSessionEntry]
    let timestamp: Date
    let version: Int  // 用于缓存格式版本控制
}

enum SessionCache {
    static let key = "cached_sessions"
    static let staleMinutes = 5

    static func save(_ sessions: [OpenClawChatSessionEntry])
    static func load() -> [OpenClawChatSessionEntry]?
    static func isStale() -> Bool
    static func clear()
}
```

### 2. 修改 ChatListView

```swift
struct ChatListView: View {
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var isRefreshing = false

    var body: some View {
        // ... existing UI ...
        .onAppear {
            // 1. 立即加载缓存显示
            if let cached = SessionCache.load() {
                sessions = cached
            }
            // 2. 后台刷新网络数据
            Task { await refreshFromNetwork() }
        }
        .refreshable {
            await refreshFromNetwork()
        }
    }

    private func loadFromCache() {
        sessions = SessionCache.load() ?? []
    }

    private func refreshFromNetwork() async {
        do {
            try await SessionManager.shared.ensureConnected()
            let transport = SessionManager.shared.makeTransport(sessionKey: "")
            let response = try await transport.listSessions(limit: 50)
            sessions = response.sessions
            SessionCache.save(response.sessions)  // 更新缓存
        } catch {
            print("Failed to refresh sessions: \(error)")
        }
    }
}
```

### 3. 离线处理

- 网络失败时继续使用缓存数据
- 无缓存且网络失败时显示空状态
- 缓存永不过期（直到下次网络刷新成功）

## 数据流

```
[App Launch]
    │
    ▼
[loadFromCache] → 有缓存？ → Yes → 显示缓存 → 后台 refresh
    │                         │
    │                         No
    ▼                         ▼
[显示空/加载状态] ← ← ← ← ← ← ← ←
    │
    ▼
[refreshFromNetwork] → 成功？ → Yes → 更新UI + 保存缓存
    │                         │
    No                        No
    │                         ▼
    ▼                    [保持现有数据 + 显示错误]
[显示缓存 + 错误提示]
```

## 错误处理

| 场景 | 行为 |
|------|------|
| 缓存存在 + 网络成功 | 更新显示 |
| 缓存存在 + 网络失败 | 显示缓存 + 静默忽略错误 |
| 缓存不存在 + 网络失败 | 显示空列表 |
| 缓存不存在 + 网络成功 | 更新显示 |

## 缓存键

- `cached_sessions` - JSON 序列化的会话数组 + 时间戳

## 实现文件

- 新增: `SmartChatApp/Core/Services/SessionCache.swift`
- 修改: `SmartChatApp/Features/ChatList/ChatListView.swift`