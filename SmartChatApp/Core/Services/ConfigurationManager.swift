import Foundation
import UIKit
import OpenClawKit

enum AppearanceTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum GatewayConnectionRole: String, CaseIterable, Codable {
    case operatorAndNode = "operator / node"
    case operatorOnly = "operator"
    case nodeOnly = "node"
}

final class ConfigurationManager: ObservableObject {
    static let shared = ConfigurationManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let gatewayRole = "openclaw_gateway_role"
        static let appearanceTheme = "openclaw_appearance_theme"
        static let autoConnectOnLaunch = "openclaw_auto_connect"
        static let deviceDisplayName = "openclaw_device_name"
        static let gatewayDebugLogs = "openclaw_gateway_debug"
        static let discoveryDebugLogs = "openclaw_discovery_debug"
        static let cameraEnabled = "openclaw_camera_enabled"
        static let locationEnabled = "openclaw_location_enabled"
        static let voiceWakeEnabled = "openclaw_voice_wake_enabled"
        static let locationMode = "openclaw_location_mode"
        static let logsNetwork = "openclaw_logs_network"
        static let logsCache = "openclaw_logs_cache"
        static let logsNativeChat = "openclaw_logs_native_chat"
        static let logsMarkdown = "openclaw_logs_markdown"
        static let collapseLongMessages = "openclaw_collapse_long_messages"
        static let renderMarkdown = "openclaw_render_markdown"
        static let showThinking = "openclaw_show_thinking"
        static let showToolCalls = "openclaw_show_tool_calls"
    }

    @Published var gatewayRole: GatewayConnectionRole {
        didSet {
            defaults.set(gatewayRole.rawValue, forKey: Keys.gatewayRole)
        }
    }

    @Published var appearanceTheme: AppearanceTheme {
        didSet {
            defaults.set(appearanceTheme.rawValue, forKey: Keys.appearanceTheme)
        }
    }

    @Published var autoConnectOnLaunch: Bool {
        didSet {
            defaults.set(autoConnectOnLaunch, forKey: Keys.autoConnectOnLaunch)
        }
    }

    @Published var deviceDisplayName: String {
        didSet {
            defaults.set(deviceDisplayName, forKey: Keys.deviceDisplayName)
        }
    }

    @Published var gatewayDebugLogs: Bool {
        didSet {
            defaults.set(gatewayDebugLogs, forKey: Keys.gatewayDebugLogs)
        }
    }

    @Published var discoveryDebugLogs: Bool {
        didSet {
            defaults.set(discoveryDebugLogs, forKey: Keys.discoveryDebugLogs)
        }
    }

    @Published var cameraEnabled: Bool {
        didSet {
            defaults.set(cameraEnabled, forKey: Keys.cameraEnabled)
        }
    }

    @Published var locationEnabled: Bool {
        didSet {
            defaults.set(locationEnabled, forKey: Keys.locationEnabled)
        }
    }

    @Published var voiceWakeEnabled: Bool {
        didSet {
            defaults.set(voiceWakeEnabled, forKey: Keys.voiceWakeEnabled)
        }
    }

    @Published var logsNetwork: Bool {
        didSet {
            defaults.set(logsNetwork, forKey: Keys.logsNetwork)
            Task { @MainActor in AppLogger.shared.setEnabled(.network, logsNetwork) }
        }
    }

    @Published var logsCache: Bool {
        didSet {
            defaults.set(logsCache, forKey: Keys.logsCache)
            Task { @MainActor in AppLogger.shared.setEnabled(.cache, logsCache) }
        }
    }

    @Published var logsNativeChat: Bool {
        didSet {
            defaults.set(logsNativeChat, forKey: Keys.logsNativeChat)
            Task { @MainActor in AppLogger.shared.setEnabled(.nativeChat, logsNativeChat) }
        }
    }

    @Published var logsMarkdown: Bool {
        didSet {
            defaults.set(logsMarkdown, forKey: Keys.logsMarkdown)
            Task { @MainActor in AppLogger.shared.setEnabled(.markdown, logsMarkdown) }
        }
    }

    @Published var locationMode: OpenClawLocationMode {
        didSet {
            defaults.set(locationMode.rawValue, forKey: Keys.locationMode)
        }
    }

    /// Whether long assistant / tool messages are collapsed with a
    /// "Show more..." button. Default ON (preserves the existing
    /// behavior for users who never touched the toggle). When OFF,
    /// `MessageBubbleView.shouldCollapse` short-circuits to false so
    /// every long bubble renders in full.
    @Published var collapseLongMessages: Bool {
        didSet {
            defaults.set(collapseLongMessages, forKey: Keys.collapseLongMessages)
        }
    }

    /// Whether to render assistant messages as markdown. Default ON.
    /// When OFF, `MessageBubbleView` skips `MarkdownCardView` and the
    /// streaming `StreamingMarkdownCardView` and falls back to plain
    /// `Text`, so the raw markdown source (e.g., `**bold**`) is shown
    /// verbatim — useful for inspecting the model's literal output.
    @Published var renderMarkdown: Bool {
        didSet {
            defaults.set(renderMarkdown, forKey: Keys.renderMarkdown)
        }
    }

    /// When OFF, hide `role == "thinking"` bubbles from the chat
    /// view. The filter is applied at the view's `messages`
    /// computed property (see `NativeChatView.swift`); the underlying
    /// store and EventInterpreter still write the bubbles. Default ON.
    @Published var showThinking: Bool {
        didSet {
            defaults.set(showThinking, forKey: Keys.showThinking)
        }
    }

    /// When OFF, hide `role == "toolCall"` and `role == "toolResult"`
    /// bubbles from the chat view. Same display-layer-only contract
    /// as `showThinking`. Default ON.
    @Published var showToolCalls: Bool {
        didSet {
            defaults.set(showToolCalls, forKey: Keys.showToolCalls)
        }
    }

    private init() {
        if let roleRaw = defaults.string(forKey: Keys.gatewayRole),
           let role = GatewayConnectionRole(rawValue: roleRaw) {
            self.gatewayRole = role
        } else {
            self.gatewayRole = .operatorAndNode
        }

        if let themeRaw = defaults.string(forKey: Keys.appearanceTheme),
           let theme = AppearanceTheme(rawValue: themeRaw) {
            self.appearanceTheme = theme
        } else {
            self.appearanceTheme = .system
        }

        self.autoConnectOnLaunch = defaults.object(forKey: Keys.autoConnectOnLaunch) as? Bool ?? false
        self.deviceDisplayName = defaults.string(forKey: Keys.deviceDisplayName) ?? UIDevice.current.name
        self.gatewayDebugLogs = defaults.object(forKey: Keys.gatewayDebugLogs) as? Bool ?? false
        self.discoveryDebugLogs = defaults.object(forKey: Keys.discoveryDebugLogs) as? Bool ?? false
        self.cameraEnabled = defaults.object(forKey: Keys.cameraEnabled) as? Bool ?? false
        self.locationEnabled = defaults.object(forKey: Keys.locationEnabled) as? Bool ?? false
        self.voiceWakeEnabled = defaults.object(forKey: Keys.voiceWakeEnabled) as? Bool ?? false
        self.logsNetwork = defaults.object(forKey: Keys.logsNetwork) as? Bool ?? false
        self.logsCache = defaults.object(forKey: Keys.logsCache) as? Bool ?? false
        self.logsNativeChat = defaults.object(forKey: Keys.logsNativeChat) as? Bool ?? false
        self.logsMarkdown = defaults.object(forKey: Keys.logsMarkdown) as? Bool ?? false

        if let modeRaw = defaults.string(forKey: Keys.locationMode),
           let mode = OpenClawLocationMode(rawValue: modeRaw) {
            self.locationMode = mode
        } else {
            self.locationMode = .whileUsing
        }

        // Default ON: existing behavior is "fold long messages" with
        // Show more; users who never opened the toggle keep the same
        // experience after the upgrade.
        self.collapseLongMessages = defaults.object(forKey: Keys.collapseLongMessages) as? Bool ?? true
        self.renderMarkdown = defaults.object(forKey: Keys.renderMarkdown) as? Bool ?? true
        self.showThinking = defaults.object(forKey: Keys.showThinking) as? Bool ?? true
        self.showToolCalls = defaults.object(forKey: Keys.showToolCalls) as? Bool ?? true

        let initialNetwork = self.logsNetwork
        let initialCache = self.logsCache
        let initialNativeChat = self.logsNativeChat
        let initialMarkdown = self.logsMarkdown
        Task { @MainActor in
            AppLogger.shared.setEnabled(.network, initialNetwork)
            AppLogger.shared.setEnabled(.cache, initialCache)
            AppLogger.shared.setEnabled(.nativeChat, initialNativeChat)
            AppLogger.shared.setEnabled(.markdown, initialMarkdown)
        }
    }

    func clear() {
        // Gateway config is now managed by ProfileManager
    }
}
