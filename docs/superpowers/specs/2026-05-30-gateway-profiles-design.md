# Gateway Profiles Design

## Context

Currently SmartChatApp supports only one Gateway connection configuration. Users need to manually edit configuration to switch between different Gateway endpoints (e.g., office, home, test environments). This design adds support for multiple saved profiles with quick switching.

## Data Model

### GatewayProfile (SwiftData @Model)

| Field | Type | Description |
|-------|------|-------------|
| id | UUID | Unique identifier |
| name | String | User-defined profile name |
| colorTag | String | Hex color code for identification |
| host | String | Gateway host address |
| port | Int | Gateway port |
| token | String | Authentication token |
| tlsEnabled | Bool | Use TLS connection |
| isActive | Bool | Currently selected profile |
| createdAt | Date | Creation timestamp |
| updatedAt | Date | Last modified timestamp |

## Storage

- SwiftData `ModelContainer` with automatic persistence
- Profile list stored in `GatewayProfile` entities
- Current active profile tracked via `isActive` flag

## UI Components

### 1. Settings Page - "Gateway Profiles" Section

```
Settings
├── Gateway
│   ├── Current: [Profile Name] ●
│   ├── [Profile List]
│   │   ├── 🟢 Office (192.168.1.100) ← active
│   │   ├── 🔵 Home (10.0.0.5)
│   │   └── 🟠 Test (test.openclaw.io)
│   └── [+ Add Profile]
│
├── Appearance
│   └── Theme: System/Light/Dark
│
├── Device
│   ├── Name: [text field]
│   └── Device ID: abc123...
│
├── Capabilities
│   ├── Camera: [toggle]
│   ├── Location: [toggle]
│   └── Voice Wake: [toggle]
```

### 2. Profile List Item

- Color dot + name + host
- Checkmark for active profile
- Swipe to delete
- Tap to switch

### 3. Add/Edit Profile Sheet

```
Edit Profile
├── Name: [text field]
├── Color: [color picker: 5 preset colors]
├── Host: [text field]
├── Port: [number field, default 443]
├── Use TLS: [toggle]
├── Token: [secure text field]
│
├── [Test Connection] (optional, tests before saving)
│
├── [Save] [Cancel]
```

### 4. Color Tags (Preset Colors)

- Green: `#10A37F` (primary)
- Blue: `#3B82F6`
- Orange: `#F97316`
- Red: `#EF4444`
- Purple: `#8B5CF6`

## Behavior

### Switching Profiles

1. User taps a profile
2. If currently connected:
   - Disconnect from current Gateway
   - Activate selected profile (`isActive = true`)
   - Connect to new Gateway
3. If not connected:
   - Activate selected profile
   - Attempt connection

### Adding Profile

1. User taps "+ Add Profile"
2. Sheet presents with empty fields
3. User fills in details
4. On save:
   - New profile created with `isActive = false`
   - If first profile, automatically set as active

### Deleting Profile

1. User swipes left on profile
2. Delete button appears
3. On delete:
   - If deleting active profile, activate another (or clear state)
   - If last profile, clear connection state

### Migration from Current Config

- On first launch with this feature:
  - Check if current UserDefaults config exists
  - Prompt user to save as first profile
  - Or auto-migrate with name "Default"

## Architecture

### Files to Modify

```
SmartChatApp/
├── Models/
│   └── GatewayProfile.swift      # New SwiftData model
├── Core/
│   ├── Services/
│   │   └── ConfigurationManager.swift  # Refactor to use GatewayProfile
│   └── Network/
│       └── SessionManager.swift   # Update to use active profile
├── Features/
│   └── Settings/
│       ├── SettingsView.swift     # Add profiles UI
│       ├── ProfileListView.swift # New
│       └── ProfileEditSheet.swift # New
```

### Key Changes

1. **ConfigurationManager refactor**
   - Keep for app-wide settings (theme, capabilities, device name)
   - Move Gateway config to GatewayProfile model

2. **SessionManager.updateActiveProfile(profile:)**
   - Disconnect current
   - Update active profile reference
   - Connect to new

3. **ConnectionFlow**
   - Load active profile on app launch
   - Auto-connect if configured

## Error Handling

- **Connection failed**: Show alert, keep previous profile active
- **Profile deleted while connected**: Disconnect first, then delete
- **Invalid profile data**: Validation before save

## Testing Scenarios

1. Create 3 profiles, switch between them
2. Delete active profile, verify auto-switch
3. Kill app, reopen, verify active profile persists
4. Test connection failure handling
5. Verify migration of existing config on first launch