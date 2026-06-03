# SmartChatApp iOS 客户端需求文档

## 1. 项目概述

### 项目名称
SmartChatApp

### 项目类型
iOS AI 聊天客户端

### 核心功能
连接 OpenClaw Gateway 的 AI 聊天应用，支持流式消息输出和交互式内容卡片渲染。

### 目标平台
iOS 17.0+

---

## 2. 技术栈

| 层级 | 技术选型 |
|------|----------|
| UI 框架 | SwiftUI |
| 架构模式 | The Composable Architecture (TCA) |
| 状态管理 | TCA (Store/State/Action/Effect) |
| 本地存储 | SwiftData |
| 网络层 | URLSession + AsyncIterator (SSE 流式) |
| 依赖管理 | Swift Package Manager |

### 主要依赖

| 库 | 版本 | 用途 |
|----|------|------|
| `swift-composable-architecture` | 2.0+ | 状态管理 |
| `swift-data` | 内置 | 本地消息持久化 |
| `swift-markdown` | 最新 | Markdown 渲染 |

---

## 3. 架构设计

### 3.1 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │  ChatListView │  │   ChatView  │  │ SettingsView │        │
│  └──────────────┘  └──────────────┘  └──────────────┘        │
├─────────────────────────────────────────────────────────────┤
│                     Feature Layer (TCA)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│  │ ChatFeature  │  │MessagesFeature│ │ConnectionFeature│    │
│  └──────────────┘  └──────────────┘  └──────────────┘        │
├─────────────────────────────────────────────────────────────┤
│                      Service Layer                           │
│  ┌──────────────────┐  ┌──────────────────┐                  │
│  │  OpenClawClient  │  │  MessageParser   │                  │
│  └──────────────────┘  └──────────────────┘                  │
│  ┌──────────────────┐  ┌──────────────────┐                  │
│  │   CardRegistry   │  │StreamingManager │                  │
│  └──────────────────┘  └──────────────────┘                  │
├─────────────────────────────────────────────────────────────┤
│                    Network Layer                             │
│              URLSession + AsyncIterator (SSE)               │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 数据流

```
用户输入
    ↓
ChatFeature.Action.sendMessage
    ↓
OpenClawClient.sessions.send (HTTP POST)
    ↓
OpenClawClient.sessions.subscribe (SSE WebSocket)
    ↓
StreamingManager 解析 events
    ↓
MessageStore 增量更新 (逐字显示)
    ↓
CardRegistry 检测 tool_call → 渲染对应卡片
```

---

## 4. OpenClaw Gateway 协议

### 4.1 连接协议

基于 WebSocket 的帧协议：

- **RequestFrame**: `{ type: "req", id: string, method: string, params?: unknown }`
- **ResponseFrame**: `{ type: "res", id: string, ok: boolean, payload?: unknown, error?: ErrorShape }`
- **EventFrame**: `{ type: "event", event: string, payload?: unknown, seq?: number }`

### 4.2 连接流程

1. 客户端发送 `ConnectParams` (协议版本范围、客户端信息、功能列表、认证)
2. 服务器返回 `hello-ok` (协商协议版本、功能列表、快照状态、授权角色)

### 4.3 关键 API

| 方法 | 说明 |
|------|------|
| `sessions.create` | 创建新会话 |
| `sessions.send` | 发送消息 (支持 thinking, attachments, timeout) |
| `sessions.subscribe` | 订阅消息流 (SSE) |
| `sessions.unsubscribe` | 取消订阅 |
| `sessions.patch` | 修改会话参数 |

### 4.4 流式事件 (OpenResponses)

| 事件类型 | 说明 |
|----------|------|
| `response.created` | 响应创建 |
| `response.in_progress` | 响应进行中 |
| `response.completed` | 响应完成 |
| `output_item.added` | 输出项添加 |
| `output_text.delta` | 文本增量 |
| `output_text.done` | 文本完成 |
| `function_call` | 函数调用 |
| `reasoning` | 推理过程 |

---

## 5. UI/UX 设计

### 5.1 UI 风格
类 ChatGPT 风格：
- 深色背景优先
- 灰色卡片展示消息
- 简洁文字排版

### 5.2 颜色方案

| 用途 | 颜色 |
|------|------|
| 背景色 | `#000000` (纯黑) |
| 卡片背景 | `#1E1E1E` (深灰) |
| 用户消息背景 | `#2E2E2E` (中灰) |
| 助理消息背景 | `#343541` (蓝灰) |
| 主色调 | `#10A37F` (ChatGPT 绿) |
| 输入框背景 | `#40414F` (暗灰) |
| 文字颜色 | `#ECECF1` (浅白) |
| 次要文字 | `#ACACBE` (灰白) |

### 5.3 屏幕结构

```
App
├── ChatListScreen (会话列表)
│   ├── NavigationStack
│   ├── ChatListView (SwiftUI List)
│   └── NavigationLink → ChatScreen
│
├── ChatScreen (聊天界面)
│   ├── NavigationStack
│   ├── MessageListView (滚动消息列表)
│   ├── StreamingIndicatorView (流式输出指示器)
│   ├── InputBarView (输入框 + 发送按钮)
│   └── CardContainerView (交互式卡片容器)
│
└── SettingsScreen (设置)
    ├── ServerConfigView (服务器配置)
    ├── AccountView (账号信息)
    └── ThemeView (主题设置)
```

### 5.4 导航结构
- `NavigationStack` 基础导航
- Tab 不使用，保持类 ChatGPT 单导航栏风格

---

## 6. 交互式卡片设计

### 6.1 卡片类型

| 工具类型 | 卡片名称 | 功能 |
|----------|----------|------|
| `music_search` | MusicCard | 播放/暂停、音量、进度条、封面显示 |
| `video_search` | VideoCard | 播放/暂停、全屏、视频信息 |
| `open_url` | ButtonCard | 点击执行操作（如打开链接） |
| `image` | ImageCard | 大图查看、图片画廊 |

### 6.2 卡片组件设计

#### MusicCard
```
┌─────────────────────────────────────┐
│ 🎵 Song Title - Artist              │
├─────────────────────────────────────┤
│ [Album Art Thumbnail]               │
│                                     │
│ ────●───────────────── 2:34/4:12   │
│                                     │
│  🔊 70%    ⏮️  ▶️/⏸️  ⏭️          │
└─────────────────────────────────────┘
```

#### VideoCard
```
┌─────────────────────────────────────┐
│ 📹 Video Title                      │
├─────────────────────────────────────┤
│ [Video Thumbnail with Play Button] │
│                                     │
│ Duration: 3:45 | HD                 │
│                                     │
│  ▶️ Play  |  🔗 Open in App         │
└─────────────────────────────────────┘
```

#### ButtonCard
```
┌─────────────────────────────────────┐
│ [Icon] Action Title                 │
├─────────────────────────────────────┤
│ Description text...                 │
│                                     │
│  ┌─────────────────────────────┐    │
│  │        [Action Button]       │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

#### ImageCard
```
┌─────────────────────────────────────┐
│ [Image - Tap to enlarge]            │
│                                     │
│  🔍 View Full Size  |  📤 Share     │
└─────────────────────────────────────┘
```

### 6.3 卡片渲染流程

```
tool_call 检测
    ↓
CardRegistry.match(toolCall.name)
    ↓
渲染对应卡片组件
    ↓
用户交互 → 执行 tool_result
    ↓
提交给 OpenClaw Gateway
```

---

## 7. 本地存储设计

### 7.1 SwiftData 模型

```swift
@Model
class ChatSession {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade) var messages: [ChatMessage]
}

@Model
class ChatMessage {
    var id: String
    var role: MessageRole  // .user, .assistant, .system
    var content: String
    var toolCalls: [ToolCall]?
    var createdAt: Date
}

@Model
class ToolCall {
    var id: String
    var name: String
    var arguments: String
    var result: String?
}
```

### 7.2 会话管理
- 会话列表按更新时间排序
- 支持删除会话
- 本地存储优先，连接后同步

---

## 8. 功能清单

### 8.1 必须功能 (MVP)

| 功能 | 描述 |
|------|------|
| 连接管理 | 连接/断开 OpenClaw Gateway |
| 会话列表 | 查看、创建、删除聊天会话 |
| 消息发送 | 发送文本消息 |
| 流式接收 | SSE 流式接收并显示响应 |
| Markdown 渲染 | 支持 Markdown 格式文本 |
| 交互式卡片 | 音乐、视频、按钮、图片卡片 |

### 8.2 后续扩展功能

| 功能 | 描述 |
|------|------|
| 用户认证 | OpenClaw 账号登录 |
| 消息搜索 | 搜索历史消息 |
| 会话导出 | 导出聊天记录 |
| 深色/浅色模式 | 主题切换 |
| 通知推送 | 新消息推送 |

---

## 9. 项目结构

```
SmartChatApp/
├── App/
│   ├── SmartChatAppApp.swift
│   └── AppDelegate.swift
├── Core/
│   ├── Network/
│   │   ├── OpenClawClient.swift
│   │   ├── WebSocketManager.swift
│   │   └── StreamingManager.swift
│   ├── Services/
│   │   ├── MessageParser.swift
│   │   └── CardRegistry.swift
│   └── Models/
│       ├── GatewayModels.swift
│       └── OpenResponsesModels.swift
├── Features/
│   ├── Chat/
│   │   ├── ChatFeature.swift
│   │   ├── ChatView.swift
│   │   └── MessageRowView.swift
│   ├── ChatList/
│   │   ├── ChatListFeature.swift
│   │   └── ChatListView.swift
│   ├── Connection/
│   │   ├── ConnectionFeature.swift
│   │   └── ConnectionView.swift
│   └── Settings/
│       ├── SettingsFeature.swift
│       └── SettingsView.swift
├── Cards/
│   ├── CardRegistry.swift
│   ├── MusicCard.swift
│   ├── VideoCard.swift
│   ├── ButtonCard.swift
│   └── ImageCard.swift
├── Design/
│   ├── Theme.swift
│   └── Typography.swift
└── Resources/
    └── Assets.xcassets
```

---

## 10. 关键技术点

### 10.1 SSE 流式处理
```swift
func streamEvents(url: URL) -> AsyncThrowingStream<GatewayEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = URLSession.shared.dataTask(for: url) { data, _, _ in
            // 解析 SSE 事件
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

### 10.2 TCA 状态管理
```swift
@Reducer
struct ChatFeature {
    struct State: Equatable {
        var messages: [Message] = []
        var inputText: String = ""
        var isStreaming: Bool = false
    }

    enum Action {
        case sendMessage(String)
        case receiveChunk(String)
        case toolCallDetected(ToolCall)
        case abortStreaming
    }
}
```

### 10.3 工具调用流程
```
1. Assistant 发送 function_call
2. 客户端检测并渲染卡片
3. 用户交互产生 result
4. 提交 FunctionCallOutput 给 Gateway
5. Gateway 继续生成响应
```

---

## 11. 风险与注意事项

| 风险 | 缓解措施 |
|------|----------|
| OpenClaw API 变化 | 协议层抽象，独立解析逻辑 |
| SSE 连接中断 | 实现重连机制 (exponential backoff) |
| 流式响应乱序 | 消息 ID 追踪，顺序渲染 |
| 卡片渲染性能 | 按需渲染，懒加载 |

---

## 12. 文档版本

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-05-08 | 初始需求文档 |
