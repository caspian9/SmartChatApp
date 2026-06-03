# Gateway Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add support for multiple saved Gateway connection profiles with quick switching

**Architecture:** SwiftData model for persistence, ConfigurationManager refactored to support profiles, SessionManager updated to use active profile

**Tech Stack:** SwiftData, SwiftUI, existing ConfigurationManager and SessionManager

---

## File Structure

```
SmartChatApp/
├── SmartChatApp/
│   ├── Models/                              # New folder
│   │   └── GatewayProfile.swift            # SwiftData @Model
│   ├── Core/
│   │   ├── Services/
│   │   │   ├── ConfigurationManager.swift   # Modified (remove gateway config, keep app settings)
│   │   │   └── ProfileManager.swift         # New (manages active profile + connections)
│   │   └── Network/
│   │       └── SessionManager.swift         # Modified (use ProfileManager)
│   ├── Features/
│   │   └── Settings/
│   │       ├── SettingsView.swift           # Modified (add profiles UI)
│   │       ├── ProfileListView.swift        # New (profile list component)
│   │       └── ProfileEditSheet.swift      # New (add/edit profile sheet)
│   └── App/
│       └── SmartChatAppApp.swift            # Modified (add SwiftData container)
```

---

## Task 1: Create GatewayProfile SwiftData Model

**Files:**
- Create: `SmartChatApp/Models/GatewayProfile.swift`
- Test: Manual verification in app

- [ ] **Step 1: Create Models folder and GatewayProfile.swift**

```swift
import Foundation
import SwiftData

@Model
final class GatewayProfile {
    var id: UUID
    var name: String
    var colorTag: String
    var host: String
    var port: Int
    var token: String
    var tlsEnabled: Bool
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorTag: String = "#10A37F",
        host: String,
        port: Int = 443,
        token: String,
        tlsEnabled: Bool = true,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorTag = colorTag
        self.host = host
        self.port = port
        self.token = token
        self.tlsEnabled = tlsEnabled
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

Run: `mkdir -p SmartChatApp/Models`

- [ ] **Step 2: Commit**

```bash
git add SmartChatApp/Models/GatewayProfile.swift
git commit -m "feat: add GatewayProfile SwiftData model"
```

---

## Task 2: Create ProfileManager Service

**Files:**
- Create: `SmartChatApp/Core/Services/ProfileManager.swift`
- Modify: `SmartChatApp/Core/Network/SessionManager.swift` (use ProfileManager)

- [ ] **Step 1: Create ProfileManager.swift**

```swift
import Foundation
import SwiftData
import OSLog

private let profileLog = Logger(subsystem: "SmartChatApp", category: "ProfileManager")

@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published var profiles: [GatewayProfile] = []
    @Published var activeProfile: GatewayProfile?

    private init() {
        setupContainer()
    }

    private func setupContainer() {
        do {
            let schema = Schema([GatewayProfile.self])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContext = modelContainer?.mainContext
            loadProfiles()
        } catch {
            logger.log("SMAlog: [ProfileManager] Failed to setup container: \(error.localizedDescription)")
        }
    }

    func loadProfiles() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<GatewayProfile>(sortBy: [SortDescriptor(\.createdAt)])
            profiles = try context.fetch(descriptor)
            activeProfile = profiles.first(where: { $0.isActive })
            profileLog.log("SMAlog: [ProfileManager] Loaded \(self.profiles.count) profiles, active: \(self.activeProfile?.name ?? "none")")
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to fetch profiles: \(error.localizedDescription)")
        }
    }

    func addProfile(name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool) -> GatewayProfile {
        guard let context = modelContext else {
            fatalError("ModelContext not initialized")
        }
        let profile = GatewayProfile(
            name: name,
            colorTag: colorTag,
            host: host,
            port: port,
            token: token,
            tlsEnabled: tlsEnabled
        )
        context.insert(profile)
        saveContext()
        loadProfiles()
        profileLog.log("SMAlog: [ProfileManager] Added profile: \(name)")
        return profile
    }

    func updateProfile(_ profile: GatewayProfile, name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool) {
        profile.name = name
        profile.colorTag = colorTag
        profile.host = host
        profile.port = port
        profile.token = token
        profile.tlsEnabled = tlsEnabled
        profile.updatedAt = Date()
        saveContext()
        loadProfiles()
    }

    func deleteProfile(_ profile: GatewayProfile) {
        guard let context = modelContext else { return }
        let wasActive = profile.isActive
        context.delete(profile)
        saveContext()
        loadProfiles()
        if wasActive {
            activateProfile(profiles.first)
        }
    }

    func activateProfile(_ profile: GatewayProfile?) {
        guard let context = modelContext else { return }
        for p in profiles {
            p.isActive = false
        }
        profile?.isActive = true
        activeProfile = profile
        saveContext()
        profileLog.log("SMAlog: [ProfileManager] Activated profile: \(profile?.name ?? "none")")
    }

    func switchToProfile(_ profile: GatewayProfile) async {
        if SessionManager.shared.isConnected {
            await SessionManager.shared.disconnect()
        }
        activateProfile(profile)
        if let profile = profile {
            await SessionManager.shared.connectWithProfile(profile)
        }
    }

    private func saveContext() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to save: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Add logger import to SessionManager and add connectWithProfile method**

Read `SmartChatApp/Core/Network/SessionManager.swift` to understand current structure, then modify to add:
```swift
func connectWithProfile(_ profile: GatewayProfile) async throws {
    let url = URL(string: "\(profile.tlsEnabled ? "https" : "http")://\(profile.host):\(profile.port)")!
    try await connectWithRole(gatewayURL: url, authToken: profile.token, role: .operatorAndNode)
}
```

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Core/Services/ProfileManager.swift SmartChatApp/Core/Network/SessionManager.swift
git commit -m "feat: add ProfileManager for gateway profile management"
```

---

## Task 3: Add SwiftData Container to App

**Files:**
- Modify: `SmartChatApp/App/SmartChatAppApp.swift`

- [ ] **Step 1: Read current SmartChatAppApp.swift**

- [ ] **Step 2: Modify to add ModelContainer**

```swift
import SwiftUI
import SwiftData

@main
struct SmartChatAppApp: App {
    @StateObject private var config = ConfigurationManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([GatewayProfile.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/App/SmartChatAppApp.swift
git commit -m "feat: add SwiftData container to app"
```

---

## Task 4: Create ProfileListView Component

**Files:**
- Create: `SmartChatApp/Features/Settings/ProfileListView.swift`
- Test: Build and run

- [ ] **Step 1: Create ProfileListView.swift**

```swift
import SwiftUI

struct ProfileListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GatewayProfile.createdAt) private var profiles: [GatewayProfile]
    @State private var showEditSheet = false
    @State private var editingProfile: GatewayProfile?
    @State private var showDeleteAlert = false
    @State private var profileToDelete: GatewayProfile?

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    var body: some View {
        Group {
            if profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .sheet(isPresented: $showEditSheet) {
            ProfileEditSheet(profile: editingProfile) { name, colorTag, host, port, token, tlsEnabled in
                if let profile = editingProfile {
                    ProfileManager.shared.updateProfile(profile, name: name, colorTag: colorTag, host: host, port: port, token: token, tlsEnabled: tlsEnabled)
                }
            }
        }
        .alert("Delete Profile", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    ProfileManager.shared.deleteProfile(profile)
                }
            }
        } message: {
            Text("Are you sure you want to delete this profile?")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No Gateway Profiles")
                .font(.headline)
                .foregroundColor(theme.textPrimary)
            Text("Add a profile to connect to a Gateway")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
            Button {
                editingProfile = nil
                showEditSheet = true
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var profileList: some View {
        ForEach(profiles) { profile in
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: profile.colorTag))
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)
                    Text(profile.host)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                if profile.isActive {
                    Image(systemName: "checkmark")
                        .foregroundColor(theme.primary)
                }

                Button {
                    Task {
                        await ProfileManager.shared.switchToProfile(profile)
                    }
                } label: {
                    Text("Connect")
                        .font(.caption)
                        .foregroundColor(theme.primary)
                }
                .disabled(profile.isActive)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    editingProfile = profile
                    showEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    profileToDelete = profile
                    showDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add SmartChatApp/Features/Settings/ProfileListView.swift
git commit -m "feat: add ProfileListView component"
```

---

## Task 5: Create ProfileEditSheet Component

**Files:**
- Create: `SmartChatApp/Features/Settings/ProfileEditSheet.swift`
- Test: Build and run

- [ ] **Step 1: Create ProfileEditSheet.swift**

```swift
import SwiftUI

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let profile: GatewayProfile?
    let onSave: (String, String, String, Int, String, Bool) -> Void

    @State private var name: String = ""
    @State private var colorTag: String = "#10A37F"
    @State private var host: String = ""
    @State private var port: String = "443"
    @State private var token: String = ""
    @State private var tlsEnabled: Bool = true

    private let colorOptions = ["#10A37F", "#3B82F6", "#F97316", "#EF4444", "#8B5CF6"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .foregroundColor(theme.textPrimary)

                    HStack {
                        Text("Color")
                        Spacer()
                        ForEach(colorOptions, id: \.self) { color in
                            Circle()
                                .fill(Color(hex: color))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(colorTag == color ? Color.primary : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    colorTag = color
                                }
                        )
                    }
                }

                Section("Connection") {
                    TextField("Host", text: $host)
                        .foregroundColor(theme.textPrimary)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    TextField("Port", text: $port)
                        .foregroundColor(theme.textPrimary)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS", isOn: $tlsEnabled)
                        .foregroundColor(theme.textPrimary)
                }

                Section("Authentication") {
                    SecureField("Token", text: $token)
                        .foregroundColor(theme.textPrimary)
                }
            }
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let portInt = Int(port) ?? 443
                        onSave(name, colorTag, host, portInt, token, tlsEnabled)
                        dismiss()
                    }
                    .disabled(name.isEmpty || host.isEmpty || token.isEmpty)
                }
            }
            .onAppear {
                if let profile = profile {
                    name = profile.name
                    colorTag = profile.colorTag
                    host = profile.host
                    port = String(profile.port)
                    token = profile.token
                    tlsEnabled = profile.tlsEnabled
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add Color hex extension to Theme.swift if not present**

Check `SmartChatApp/Design/Theme.swift` - Color hex init should already exist from earlier work.

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Features/Settings/ProfileEditSheet.swift
git commit -m "feat: add ProfileEditSheet component"
```

---

## Task 6: Integrate into SettingsView

**Files:**
- Modify: `SmartChatApp/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Read current SettingsView.swift to find Gateway section**

- [ ] **Step 2: Replace static Gateway section with ProfileListView**

Find the "Gateway" section (around line 33-36) and replace the connection UI with:
```swift
Section("Gateway") {
    ProfileListView()
}
```

Remove the old `ConnectionConfigSheet` reference and related state since that's now handled by ProfileListView.

- [ ] **Step 3: Update checkConnection and related methods to use ProfileManager**

- [ ] **Step 4: Commit**

```bash
git add SmartChatApp/Features/Settings/SettingsView.swift
git commit -m "feat: integrate profiles into Settings view"
```

---

## Task 7: Migration from Current Config

**Files:**
- Modify: `SmartChatApp/Core/Services/ProfileManager.swift`

- [ ] **Step 1: Add migration method to ProfileManager**

Add a method that checks if existing config exists in UserDefaults and migrates to first profile:
```swift
func migrateFromLegacyConfig() {
    guard profiles.isEmpty else { return }
    let config = ConfigurationManager.shared
    guard config.isConfigured else { return }
    
    let profile = addProfile(
        name: "Default",
        colorTag: "#10A37F",
        host: config.gatewayHost,
        port: config.gatewayPort,
        token: config.authToken,
        tlsEnabled: config.gatewayUseTLS
    )
    activateProfile(profile)
}
```

- [ ] **Step 2: Call migration on app launch in RootView or ProfileManager init**

- [ ] **Step 3: Commit**

```bash
git add SmartChatApp/Core/Services/ProfileManager.swift
git commit -m "feat: add legacy config migration"
```

---

## Task 8: Build and Verify

- [ ] **Step 1: Run make build to verify compilation**
- [ ] **Step 2: Test profile creation, switching, deletion**
- [ ] **Step 3: Verify connection works with new profile**
- [ ] **Step 4: Push all commits**

---

## Notes

- SwiftData requires iOS 17+ (matches project deployment target of iOS 18)
- ProfileManager is @MainActor singleton for thread safety
- SessionManager still handles actual connection logic, ProfileManager orchestrates profile switching
- Color hex extension already exists in Theme.swift from earlier work