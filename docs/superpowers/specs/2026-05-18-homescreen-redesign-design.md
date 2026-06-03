# HomeScreen Redesign Design

## Goal

Redesign the app's home screen with two entry points: NativeChat and ChatList.

## Layout

```
┌─────────────────────────┐
│      SmartChatApp        │
├─────────────────────────┤
│                          │
│   ┌─────────┐ ┌─────────┐│
│   │ Native  │ │  Chat   ││
│   │  Chat   │ │  List   ││
│   │  💬    │ │  📋    ││
│   └─────────┘ └─────────┘│
│                          │
│   当前设备: Hai's iPhone  │
│                          │
└─────────────────────────┘
```

## Components

### 1. HomeView (Root)

- Navigation title: "SmartChatApp"
- Vertical stack layout with centered cards
- Device info at bottom

### 2. EntryCard

- Size: ~150x120 pts
- Background: #1E1E1E with 12pt corner radius
- Icon: SF Symbol, 48pt, centered
- Label: 14pt text below icon
- States: default, pressed (opacity 0.7)

### 3. DeviceInfoView

- Display current paired device name
- Subtle text styling with gray color

## Entry Points

| Card | Icon | Destination |
|------|------|-------------|
| Native Chat | bubble.left.and.bubble.right | NativeChatView (placeholder for future) |
| Chat List | list.bullet | ChatListView (existing) |

## Implementation

- Create: `SmartChatApp/Features/Home/HomeView.swift`
- Modify: App entry point to use HomeView as root

## Future Extensions

- NativeChatView will be implemented in subsequent tasks
- SessionSelector component planned for session filtering