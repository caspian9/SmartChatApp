import Foundation
import UIKit
import OpenClawKit

enum AppearanceTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum GatewayConnectionRole: String, CaseIterable {
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

    @Published var locationMode: OpenClawLocationMode {
        didSet {
            defaults.set(locationMode.rawValue, forKey: Keys.locationMode)
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

        if let modeRaw = defaults.string(forKey: Keys.locationMode),
           let mode = OpenClawLocationMode(rawValue: modeRaw) {
            self.locationMode = mode
        } else {
            self.locationMode = .whileUsing
        }
    }

    func clear() {
        // Gateway config is now managed by ProfileManager
    }
}
