# SmartChatApp App 内日志系统设计

> **Status: Active (2026-06-04).** 设计 SmartChatApp 自有的应用层日志采集、UI 展示、Settings 控制开关。本设计**不**改动 SDK (OpenClawKit) 内部的日志机制 (`Gateway Debug Logs` / `Discovery Debug Logs` 那条线保持原状)。

## 1. 背景

### 1.1 问题

当前应用代码的日志全部走 `os_log` / `Logger` 打到系统 Console.app:

- 11 个 subsystem/category,前缀统一为 `SMAlog:`,需要外接 Console 才能查看
- 真机运行场景下,从 Console 取日志要拔线接 Mac,流程繁琐
- 日志无法在运行时被复制、过滤或导出

`SettingsView` 的 Gateway → Advanced 里已有两个 SDK 调试开关 (`Gateway Debug Logs`、`Discovery Debug Logs`) 和一个 `Discovery Logs` viewer 入口,但该 viewer 只展示 SDK 内部 `DebugLogEntry` 的一次性快照,与 app 代码无关。

### 1.2 目标

- 应用代码的日志可被 app 内 UI 实时查看、过滤、搜索、复制
- 通过 Settings 开关控制采集范围,关闭时无性能开销
- 系统 Console 行为不变,Xcode 调试体验保留
- 不动 SDK 内部日志链路

### 1.3 不在范围

- SDK (OpenClawKit) 内部日志的统一展示 (Gateway / Discovery 仍走原 viewer)
- 日志持久化到文件 (本期仅内存)
- 网络上传 / 远程聚合
- 崩溃日志收集
- 按日志级别 (Debug / Info / Warning / Error) 的 UI 过滤 (level 字段在数据模型里保留,但本期 viewer 不暴露级别筛选 UI)

---

## 2. 现状

### 2.1 Settings 当前结构

```
Form
├─ Gateway
│   ├─ ProfileListView
│   └─ Advanced (DisclosureGroup)
│       ├─ Toggle Auto-connect on Launch
│       ├─ Toggle Gateway Debug Logs        ← SDK SessionManager 控制
│       ├─ Toggle Discovery Debug Logs      ← SDK SessionManager 控制
│       └─ NavigationLink Discovery Logs    ← SDK 快照 viewer
├─ Device
├─ Appearance
├─ Cache
└─ About
```

### 2.2 应用日志现状

11 个 subsystem/category,可按职责分 4 组:

| 模块 | 涉及文件 |
|------|---------|
| Network | `SessionManager`、`ProfileManager` |
| Cache | `MessageCache`、`MarkdownCache`、`CollapseStateCache` |
| NativeChat | `NativeChatView`、`NativeChatViewModel`、`SessionPickerView`、`MessageBubbleView` |
| Markdown | `MarkdownStreamManager` |

约 70 处 `os_log(...)` / `Logger.log(...)` 调用,均以 `SMAlog:` 前缀开头。

### 2.3 缺口

- 没有 app 内 buffer 可被 UI 读取
- `DiscoveryLogsView` 一次性快照,不刷新、不过滤、不搜索
- Settings 没有专门的 Debug 区分

---

## 3. 关键决策

| # | 决策点 | 选择 |
|---|--------|------|
| D1 | 查看器形态 | 统一一个 `Debug Logs` viewer (仅 AppLogger 日志,SDK 仍走原 viewer) |
| D2 | 控制粒度 | 按 4 个模块独立 toggle (Network / Cache / NativeChat / Markdown) |
| D3 | 采集机制 | `AppLogger` wrapper,迁移现有 `os_log` 调用,同时写 OSLog + 内存 buffer |
| D4 | Buffer 策略 | 内存 only 环形 buffer,容量 2000 条,app 重启清空 |
| D5 | Viewer 功能 | Live tail + 模块 filter chips + 文本搜索 + Pause/Resume + Copy |

---

## 4. 架构

### 4.1 数据流

```
代码各处 ─ AppLogger.log(msg, category:, level:) ─┬─→ os_log (系统 Console,始终写)
                                                  │
                                                  └─→ ring buffer ([LogEntry], cap=2000)
                                                       (only when category enabled)
                                                                │
                                                                ▼
                              ConfigurationManager ─→ AppLogger.setEnabled(category:, on:)
                                  (4 个 @Published Bool 绑定 Settings toggle)
                                                                │
                                                                ▼
                                                          DebugLogsView
                                                          (订阅 @Published entries,
                                                           live tail / filter / search / pause)
```

### 4.2 组件

| 组件 | 位置 | 职责 |
|------|------|------|
| `AppLogger` | `Core/Services/AppLogger.swift` (新) | 单例,持有 ring buffer + enabledCategories,提供静态 `log()` 入口 |
| `LogEntry` | `AppLogger.swift` | 单条日志数据 (id, ts, category, level, message) |
| `LogCategory` | `AppLogger.swift` | enum: network / cache / nativeChat / markdown |
| `LogLevel` | `AppLogger.swift` | enum: debug / info / warning / error |
| `ConfigurationManager` (改动) | `Core/Services/ConfigurationManager.swift` | 新增 4 个 `@Published Bool`,绑定 UserDefaults,didSet 时调 `AppLogger.shared.setEnabled` |
| `DebugLogsView` | `Features/Settings/DebugLogsView.swift` (新) | 订阅 `AppLogger.shared.$entries`,实现 live tail / filter / search / pause / copy |
| `SettingsView` (改动) | `Features/Settings/SettingsView.swift` | 在 `About` 之后追加 `Debug & Logs` section |

### 4.3 不变的部分

- 现有 `DiscoveryLogsView` 完全保留,功能不动
- 现有 `Gateway Debug Logs` / `Discovery Debug Logs` toggle 保留在 Gateway → Advanced 原位 (它们走 SDK 链路,与 AppLogger 是两套机制)
- 所有 `OSLog` subsystem 字符串保留,AppLogger 内部按 category 复用现有 subsystem (Xcode / Console 的过滤体验不变)

---

## 5. 数据模型

```swift
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
        case .warning: return .default   // OSLog 没有独立 warning,降到 default
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
```

---

## 6. AppLogger API

```swift
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    private let capacity = 2000
    @Published private(set) var entries: [LogEntry] = []
    private var enabledCategories: Set<LogCategory> = []

    // 每个 category 一个 OSLog,subsystem 与现有代码一致
    private let osLogs: [LogCategory: OSLog] = [
        .network:    OSLog(subsystem: "SmartChatApp", category: "Network"),
        .cache:      OSLog(subsystem: "SmartChatApp", category: "Cache"),
        .nativeChat: OSLog(subsystem: "SmartChatApp", category: "NativeChat"),
        .markdown:   OSLog(subsystem: "SmartChatApp", category: "Markdown"),
    ]

    func setEnabled(_ category: LogCategory, _ on: Bool)
    func clear()

    /// 主入口。OSLog 始终写;buffer 仅在 category 启用时写。
    static func log(_ message: String,
                    category: LogCategory,
                    level: LogLevel = .debug)
}
```

线程模型:
- `AppLogger` 标 `@MainActor`,`entries` 在主线程更新 (SwiftUI 友好)
- `log(...)` 静态入口可在任意线程调用;OSLog 写入是线程安全的;buffer 写入 dispatch 到 `Task { @MainActor in ... }`
- 调用方无需感知线程,跟现有 `os_log` 用法等价

性能:
- toggle off 时,只走 `os_log`,buffer 早返;不分配 `LogEntry`,不入队
- toggle on 时,每条多一次 `LogEntry` 分配 + 主线程 hop;在 NativeChat 流式日志高峰下 (~200 entry/s) 可接受
- 环形 buffer 用 `Array` + 当 `entries.count >= capacity` 时 `entries.removeFirst()`;若发现性能瓶颈,后期可换 `Deque`

---

## 7. Settings UI 变更

只改 `SettingsView.swift`,在 `About` section 之后追加一个新 section:

```swift
Section("Debug & Logs") {
    Toggle("Network Logs", isOn: $config.networkLogs)
        .onChange(of: config.networkLogs) { _, on in
            AppLogger.shared.setEnabled(.network, on)
        }
    Toggle("Cache Logs", isOn: $config.cacheLogs)
        .onChange(of: config.cacheLogs) { _, on in
            AppLogger.shared.setEnabled(.cache, on)
        }
    Toggle("NativeChat Logs", isOn: $config.nativeChatLogs)
        .onChange(of: config.nativeChatLogs) { _, on in
            AppLogger.shared.setEnabled(.nativeChat, on)
        }
    Toggle("Markdown Logs", isOn: $config.markdownLogs)
        .onChange(of: config.markdownLogs) { _, on in
            AppLogger.shared.setEnabled(.markdown, on)
        }

    NavigationLink("Debug Logs Viewer") {
        DebugLogsView()
    }

    Button("Clear Logs") {
        AppLogger.shared.clear()
    }
    .foregroundColor(.red)
}
```

`ConfigurationManager` 新增 4 个 `@Published Bool` (`networkLogs`、`cacheLogs`、`nativeChatLogs`、`markdownLogs`),默认全 `false`,UserDefaults key 命名沿用现有风格 `openclaw_logs_<category>`。在 `init` 末尾根据 UserDefaults 值同步调用 `AppLogger.shared.setEnabled(...)`,保证 app 启动后状态一致。

Gateway → Advanced 里的两个 SDK toggle 和 Discovery Logs 入口**不动**。

---

## 8. Debug Logs Viewer 设计

```
┌─────────────────────────────────────────────┐
│ ‹ Debug Logs              [Copy] [Pause]    │  ← navigationTitle + toolbar
├─────────────────────────────────────────────┤
│ [Network✓] [Cache✓] [NativeChat✓] [MD✓]     │  ← 4 个 chip
│ [🔍 search...                            ]  │
├─────────────────────────────────────────────┤
│ 16:42:03 [nativeChat] scrollTrigger -> 5    │  ← ScrollView + LazyVStack
│ 16:42:03 [markdown]   appendCumulative id=… │
│ 16:42:04 [cache]      MessageCache get …    │
│ ...                                         │
└─────────────────────────────────────────────┘
```

### 8.1 State

```swift
struct DebugLogsView: View {
    @ObservedObject private var logger = AppLogger.shared
    @State private var enabledChips: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var searchText: String = ""
    @State private var isPaused: Bool = false
    @State private var frozenEntries: [LogEntry] = []
}
```

### 8.2 Display 列表

派生 `displayEntries`:
- 数据源: `isPaused ? frozenEntries : logger.entries`
- 过滤: 保留 `enabledChips.contains(entry.category)` 的
- 搜索: 若 `searchText` 非空,保留 `message` 含 `searchText` (case-insensitive) 的

### 8.3 行为

| 操作 | 行为 |
|------|------|
| 进入页面 | 订阅 `logger.$entries`,显示历史 + live tail |
| 点击 chip | 切换 `enabledChips` 成员,列表立即重过滤 |
| 输入 search | 实时过滤;搜索期间 live tail 仍工作 |
| 点 Pause | `frozenEntries = logger.entries`,`isPaused = true`;之后列表来自 frozen 副本,新日志仍进 `logger.entries` (buffer) 但不显示 |
| 点 Resume | `isPaused = false`,`frozenEntries = []`,列表恢复订阅 |
| 点 Copy | 把当前 `displayEntries` 格式化为 `<ISO ts> [<category>] <message>\n...` 写入 `UIPasteboard.general.string` |
| live tail 滚动 | 新条目到达且**未** Pause、**未** 用户上滑时,自动 `scrollTo(.last, anchor: .bottom)` |

> Live tail 的"未用户上滑"判定参考 `NativeChatView` 里的 `isUserScrolling` 标志做法,后续在实施计划里细化。

---

## 9. 迁移计划

11 个文件的批量替换。每文件统一处理:

1. 删除 `private let xxxLog = OSLog(...)` / `private let logger = Logger(...)`
2. 把所有 `os_log("SMAlog: ...", log: xxxLog, type: .debug, args...)` 替换为 `AppLogger.log("...", category: .xxx)`
3. 把所有 `logger.log("SMAlog: ...")` 替换为 `AppLogger.log("...", category: .xxx)`
4. 保留 `SMAlog:` 前缀 (跟现有 grep 习惯一致)

| 文件 | category | 调用数 (approx) |
|------|----------|-----------------|
| `SessionManager.swift` | `.network` | ? |
| `ProfileManager.swift` | `.network` | ? |
| `MessageCache.swift` | `.cache` | ~7 |
| `MarkdownCache.swift` | `.cache` | ? |
| `CollapseStateCache.swift` | `.cache` | ~3 |
| `NativeChatView.swift` | `.nativeChat` | ~10 |
| `NativeChatViewModel.swift` | `.nativeChat` | ~5 |
| `SessionPickerView.swift` | `.nativeChat` | ? |
| `MessageBubbleView.swift` | `.nativeChat` | ~8 |
| `MarkdownStreamManager.swift` | `.markdown` | ~10 |

精确条数在实施阶段每文件 grep 确认。

格式化字符串简化:`os_log` 的 `%{public}s` / `%{public}d` 等 format specifier 在迁移时改为 Swift 字符串插值 (`"\(value)"`),因为 AppLogger 内部对 OSLog 用 `%{public}@` 投递整段已渲染字符串。这会让原日志中带 `%{private}` 的字段也变 public — 检查现有日志中是否有任何 `%{private}` 标记;有则在 spec 实施时单独处理 (例如对 `text` 内容做截断 + 标记)。

---

## 10. 不在本期范围

- **SDK 日志统一**:Gateway / Discovery 日志的实时合并显示。需要 hook 进 SDK `SessionManager.debugLog` 流,改动跨模块,留作后续。
- **日志级别 filter UI**:`LogLevel` 字段已就位,viewer 暂只按 category 过滤。后续可加级别 chip。
- **持久化**:不写盘。后续若需复现间歇性 bug,可加 `Documents/Logs/` 滚动文件。
- **导出文件 / 分享**:仅 Copy 到剪贴板。后续可加 `ShareLink` 导出 .log。
- **远程上传**:不做。
- **崩溃日志**:不做。

---

## 11. 验收清单

- [ ] `AppLogger` 单例存在,4 个 category 各自可 toggle
- [ ] toggle off 时,代码里的 `AppLogger.log(...)` 仍写 OSLog,**不**写 buffer (Instruments 验证无分配)
- [ ] toggle on 时,日志立即出现在 `DebugLogsView`,延迟 < 100ms
- [ ] 11 个文件全部迁移完成,无 `os_log(...` / `Logger(subsystem:` 残留 (`grep` 验证)
- [ ] `DebugLogsView` 支持:live tail / 4 个 chip 切换 / 文本搜索 / Pause-Resume / Copy
- [ ] Settings `Debug & Logs` section 出现在 `About` 之后,4 个 toggle + viewer 入口 + Clear 按钮齐全
- [ ] 现有 Gateway → Advanced 里的两个 SDK toggle 和 `Discovery Logs` 入口**未动**
- [ ] app 重启后 buffer 清空,toggle 状态从 UserDefaults 恢复
- [ ] 环形 buffer 在 2000 条之后正确 FIFO 覆盖,内存稳定

---

## 12. 参考

- 现状代码: `SmartChatApp/Features/Settings/SettingsView.swift`、`SmartChatApp/Features/Settings/DiscoveryLogsView.swift`、`SmartChatApp/Core/Services/ConfigurationManager.swift`
- 关联 spec: `docs/spec/2026-05-08-smartchatapp-design.md` (项目总览)
- 关联 CLAUDE.md: `Core/Services/` 章节列出现有 Manager 清单,新增 `AppLogger` 应同步更新
