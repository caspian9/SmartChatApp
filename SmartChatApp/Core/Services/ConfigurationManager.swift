import Foundation

enum AppearanceTheme: String, CaseIterable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"
}

final class ConfigurationManager: ObservableObject {
    static let shared = ConfigurationManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let gatewayHost = "openclaw_gateway_host"
        static let gatewayPort = "openclaw_gateway_port"
        static let gatewayUseTLS = "openclaw_gateway_use_tls"
        static let authToken = "openclaw_auth_token"
        static let appearanceTheme = "openclaw_appearance_theme"
    }

    @Published var gatewayHost: String {
        didSet {
            defaults.set(gatewayHost, forKey: Keys.gatewayHost)
        }
    }

    @Published var gatewayPort: Int {
        didSet {
            defaults.set(gatewayPort, forKey: Keys.gatewayPort)
        }
    }

    @Published var gatewayUseTLS: Bool {
        didSet {
            defaults.set(gatewayUseTLS, forKey: Keys.gatewayUseTLS)
        }
    }

    @Published var authToken: String {
        didSet {
            defaults.set(authToken, forKey: Keys.authToken)
        }
    }

    @Published var appearanceTheme: AppearanceTheme {
        didSet {
            defaults.set(appearanceTheme.rawValue, forKey: Keys.appearanceTheme)
        }
    }

    private init() {
        self.gatewayHost = defaults.string(forKey: Keys.gatewayHost) ?? ""

        var port = defaults.integer(forKey: Keys.gatewayPort)
        if port == 0 {
            port = 443
        }
        self.gatewayPort = port

        self.gatewayUseTLS = defaults.object(forKey: Keys.gatewayUseTLS) as? Bool ?? true
        self.authToken = defaults.string(forKey: Keys.authToken) ?? ""

        if let themeRaw = defaults.string(forKey: Keys.appearanceTheme),
           let theme = AppearanceTheme(rawValue: themeRaw) {
            self.appearanceTheme = theme
        } else {
            self.appearanceTheme = .system
        }
    }

    func clear() {
        gatewayHost = ""
        gatewayPort = 443
        gatewayUseTLS = true
        authToken = ""
    }

    var isConfigured: Bool {
        !gatewayHost.isEmpty && !authToken.isEmpty
    }

    var gatewayURL: URL? {
        let scheme = gatewayUseTLS ? "wss" : "ws"

        var host = gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("https://") {
            host = String(host.dropFirst(8))
        } else if host.hasPrefix("http://") {
            host = String(host.dropFirst(7))
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = gatewayPort
        components.path = "/gateway"
        return components.url
    }

    var displayURL: String {
        let scheme = gatewayUseTLS ? "https" : "http"
        var result = "\(scheme)://\(gatewayHost)"
        if (gatewayUseTLS && gatewayPort != 443) || (!gatewayUseTLS && gatewayPort != 80) {
            result += ":\(gatewayPort)"
        }
        return result
    }
}
