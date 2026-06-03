# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SmartChatApp is an iOS AI chat application that connects to OpenClaw Gateway, supporting streaming message output and interactive content cards (music, video, buttons, images).

**Tech Stack:** SwiftUI, The Composable Architecture (TCA) 2.0+, SwiftData, XcodeGen, Swift Package Manager

## Build Commands

```bash
# Generate Xcode project
cd SmartChatApp && xcodegen generate

# Build
xcodebuild build -scheme SmartChatApp -quiet

# Test
xcodebuild test -scheme SmartChatAppTests

# Run (requires Xcode)
open SmartChatApp.xcodeproj
```

## Architecture

### Layered Architecture

```
Presentation Layer (SwiftUI Views)
    ↓
Feature Layer (TCA Reducers)
    ↓
Service Layer (OpenClawClient, CardRegistry)
    ↓
Network Layer (URLSession + SSE Streaming)
```

### TCA Pattern

Each feature follows TCA pattern:
- `FeatureName.swift` — Contains `@Reducer struct FeatureName` with `State`, `Action`, and `body`
- `FeatureNameView.swift` — SwiftUI view using `StoreOf<FeatureName>`

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `OpenClawClient` | `Core/Network/` | Gateway WebSocket connection |
| `StreamingManager` | `Core/Network/` | SSE event parsing |
| `CardRegistry` | `Core/Services/` | Interactive card rendering |
| `ChatFeature` | `Features/Chat/` | Chat state management |
| `ChatListFeature` | `Features/ChatList/` | Session list management |

## OpenClaw Gateway Protocol

### Connection Flow
1. Connect via WebSocket to Gateway URL
2. Send `ConnectParams` with protocol version and auth
3. Receive `hello-ok` with negotiated features
4. Use `sessions.create/send/subscribe` for messaging

### Key API Methods
- `sessions.create` — Create new session
- `sessions.send` — Send message (HTTP POST)
- `sessions.subscribe` — Subscribe to message stream (SSE)
- `sessions.patch` — Modify session parameters

### Streaming Events
- `response.created`, `response.in_progress`, `response.completed`
- `output_text.delta`, `output_text.done`
- `function_call`, `reasoning`

## Card System

Cards are rendered based on tool call names:
- `music_search` → MusicCard (play/pause, progress, volume)
- `video_search` → VideoCard (play, fullscreen)
- `open_url` → ButtonCard (open links)
- `image` → ImageCard (view full size)

## Project Structure

```
SmartChatApp/
├── App/
├── Core/
│   ├── Network/     # OpenClawClient, WebSocketManager, StreamingManager
│   ├── Services/    # CardRegistry, MessageParser
│   └── Models/      # GatewayModels, DomainModels
├── Features/
│   ├── Chat/        # ChatFeature, ChatView, MessageRowView
│   ├── ChatList/    # ChatListFeature, ChatListView
│   ├── Connection/  # ConnectionFeature, ConnectionView
│   └── Settings/    # SettingsFeature, SettingsView
├── Cards/           # MusicCard, VideoCard, ButtonCard, ImageCard
└── Design/          # Theme, Typography
```

## Documentation

- Spec: `docs/spec/2026-05-08-smartchatapp-design.md`
- Plan: `docs/superpowers/plans/2026-05-08-smartchatapp-implementation.md`
