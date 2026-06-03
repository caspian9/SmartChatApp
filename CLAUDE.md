# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SmartChatApp is an iOS AI chat application that connects to OpenClaw Gateway, supporting streaming message output and interactive content cards (music, video, buttons, images).

**Tech Stack:** SwiftUI, The Composable Architecture (TCA) 2.0+, SwiftData, XcodeGen, Swift Package Manager

## Build Commands

```bash
# Generate Xcode project (run from SmartChatApp root)
xcodegen generate

# Build for iOS Simulator
xcodebuild build -scheme SmartChatApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet

# Build for iPhone device
xcodebuild build -scheme SmartChatApp -destination "platform=iOS,id=F3F7FE5F-4CBE-581B-BD90-A0E7A3CBA1A1" -allowProvisioningUpdates build

# Install to iPhone (via xcrun devicectl)
xcrun devicectl device install app --device F3F7FE5F-4CBE-581B-BD90-A0E7A3CBA1A1 ~/Library/Developer/Xcode/DerivedData/SmartChatApp-*/Build/Products/Debug-iphoneos/SmartChatApp.app

# List connected devices
xcrun devicectl list devices

# Test
xcodebuild test -scheme SmartChatAppTests

# Open in Xcode
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
| `SessionManager` | `SmartChatApp/Core/Network/` | Gateway connection management (operator/node roles) |
| `StreamingManager` | `SmartChatApp/Core/Network/` | SSE event parsing |
| `WebSocketManager` | `SmartChatApp/Core/Network/` | Raw WebSocket transport |
| `CardRegistry` | `SmartChatApp/Core/Services/` | Interactive card rendering |
| `ChatFeature` | `SmartChatApp/Features/Chat/` | Chat state management |
| `ChatListFeature` | `SmartChatApp/Features/ChatList/` | Session list management |
| `NodeCommandRouter` | `SmartChatApp/Core/NodeHandlers/` | Node command dispatch (location.get, device.status, etc.) |
| `LocationService` | `SmartChatApp/Core/NodeHandlers/` | CoreLocation async/await wrapper |
| `DeviceService` | `SmartChatApp/Core/NodeHandlers/` | Device status and info |

### Node Command Handlers

Node commands are handled by `NodeCommandRouter` via the `onInvoke` callback during node connection:

| Command | Handler | Status |
|---------|---------|--------|
| `location.get` | LocationService | Full implementation |
| `device.status` | DeviceService | Full implementation (battery, thermal, storage, network) |
| `device.info` | DeviceService | Full implementation (device name, model, OS, app version) |
| `canvas.*` | stub | Returns ok: true |
| `screen.record` | stub | Returns ok: true |
| `talk.ptt.*` | stub | Returns ok: true |
| `camera.*` | stub | Returns ok: true |
| `photos.latest` | stub | Returns ok: true |
| `contacts.*` | stub | Returns ok: true |
| `calendar.*` | stub | Returns ok: true |
| `reminders.*` | stub | Returns ok: true |

### Card Components

| Card | Location | Purpose |
|------|----------|---------|
| `MusicCard` | `SmartChatApp/Cards/` | Music playback controls |
| `VideoCard` | `SmartChatApp/Cards/` | Video playback controls |
| `ButtonCard` | `SmartChatApp/Cards/` | Action buttons (open URL etc.) |
| `ImageCard` | `SmartChatApp/Cards/` | Image display with fullscreen |

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
├── project.yml              # XcodeGen configuration
├── Package.swift            # SPM dependencies
├── SmartChatApp.xcodeproj/  # Generated Xcode project
├── SmartChatApp/            # Main source directory
│   ├── App/
│   │   └── SmartChatAppApp.swift
│   ├── Core/
│   │   ├── Models/         # DomainModels, GatewayModels
│   │   ├── Network/        # SessionManager, StreamingManager, WebSocketManager
│   │   ├── NodeHandlers/   # NodeCommandRouter, LocationService, DeviceService
│   │   └── Services/       # CardRegistry, MessageParser, ConfigurationManager
│   ├── Features/
│   │   ├── Chat/           # ChatFeature, ChatView, MessageRowView
│   │   ├── ChatList/       # ChatListFeature, ChatListView
│   │   ├── Connection/      # ConnectionFeature, ConnectionView
│   │   └── Settings/       # SettingsFeature, SettingsView
│   ├── Cards/              # MusicCard, VideoCard, ButtonCard, ImageCard
│   ├── Design/             # Theme, Typography
│   └── Resources/          # Assets.xcassets
├── SmartChatAppTests/      # Unit tests
├── docs/                   # Specification and plans
└── CLAUDE.md
```

## Documentation

- Spec: `docs/spec/2026-05-08-smartchatapp-design.md`
- Plan: `docs/superpowers/plans/2026-05-08-smartchatapp-implementation.md`
