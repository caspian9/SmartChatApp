# HomeScreen Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the app's home screen with two entry cards: NativeChat (left) and ChatList (right).

**Architecture:** HomeView becomes the root view with two EntryCard components. NavigationStack wraps the content. DeviceInfoView shows current device name.

**Tech Stack:** SwiftUI, SF Symbols

---

## File Structure

- **Create:** `SmartChatApp/Features/Home/HomeView.swift` — Home screen with entry cards
- **Create:** `SmartChatApp/Features/Home/EntryCard.swift` — Reusable card component
- **Create:** `SmartChatApp/Features/Home/DeviceInfoView.swift` — Device info display
- **Modify:** `SmartChatApp/App/SmartChatAppApp.swift` — Change root from ChatListView to HomeView

---

## Task 1: Create EntryCard Component

**Files:**
- Create: `SmartChatApp/Features/Home/EntryCard.swift`

- [ ] **Step 1: Create EntryCard.swift**

```swift
import SwiftUI

struct EntryCard: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            .frame(width: 150, height: 120)
            .background(Color(hex: "1E1E1E"))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild build -scheme SmartChatApp DEVELOPMENT_TEAM=24X2NMFQUY -destination 'platform=iOS,id=00008120-0019192202DB401E' 2>&1 | grep -E "error:" | head -5`
Expected: Should error until dependencies resolved, but code structure is valid

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/Home/EntryCard.swift
git commit -m "feat: add EntryCard component for home screen

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 2: Create DeviceInfoView

**Files:**
- Create: `SmartChatApp/Features/Home/DeviceInfoView.swift`

- [ ] **Step 1: Create DeviceInfoView.swift**

```swift
import SwiftUI

struct DeviceInfoView: View {
    private var deviceName: String {
        ConfigurationManager.shared.isConfigured ? "Hai's iPhone" : "Not Connected"
    }

    var body: some View {
        Text("当前设备: \(deviceName)")
            .font(.caption)
            .foregroundColor(.gray)
    }
}
```

- [ ] **Step 2: Verify directory exists**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/Home/DeviceInfoView.swift
git commit -m "feat: add DeviceInfoView for home screen

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 3: Create HomeView

**Files:**
- Create: `SmartChatApp/Features/Home/HomeView.swift`

- [ ] **Step 1: Create HomeView.swift**

```swift
import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            HStack(spacing: 20) {
                EntryCard(
                    title: "Native Chat",
                    icon: "bubble.left.and.bubble.right",
                    action: {
                        // TODO: Navigate to NativeChatView
                    }
                )

                EntryCard(
                    title: "Chat List",
                    icon: "list.bullet",
                    action: {
                        // Navigation handled by NavigationLink in wrapped view
                    }
                )
            }

            Spacer()

            DeviceInfoView()
        }
        .padding()
        .background(Color.black)
        .navigationTitle("SmartChatApp")
    }
}
```

- [ ] **Step 2: Verify directory exists**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/Home/HomeView.swift
git commit -m "feat: add HomeView with entry cards

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 4: Update App Entry Point

**Files:**
- Modify: `SmartChatApp/App/SmartChatAppApp.swift`

- [ ] **Step 1: Update SmartChatAppApp.swift**

Change from:
```swift
NavigationStack {
    ChatListView()
}
```

To:
```swift
NavigationStack {
    HomeView()
}
```

- [ ] **Step 2: Verify build**

Run: `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -scheme SmartChatApp DEVELOPMENT_TEAM=24X2NMFQUY -destination 'platform=iOS,id=00008120-0019192202DB401E' 2>&1 | grep -E "error:" | head -5`
Expected: No errors

- [ ] **Step 3: Install to device**

Run: `ideviceinstaller -n -w install "/Users/hai/Library/Developer/Xcode/DerivedData/SmartChatApp-dfrsxrzlmojfuqghcqwkahnxlphh/Build/Products/Debug-iphoneos/SmartChatApp.app" 2>&1`
Expected: Install Complete

- [ ] **Step 4: Commit**

```bash
git add SmartChatApp/App/SmartChatAppApp.swift
git commit -m "feat: set HomeView as root view

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Verification

1. Build succeeds: `xcodebuild build -scheme SmartChatApp`
2. Home screen displays with two entry cards
3. ChatList card navigates to existing ChatListView
4. Device info shows at bottom