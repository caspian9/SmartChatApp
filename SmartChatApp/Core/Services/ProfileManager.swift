import Foundation

@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    private let defaults = UserDefaults.standard
    private let storageKey = "gateway_profiles"

    @Published var profiles: [GatewayProfile] = []
    @Published var activeProfile: GatewayProfile?

    private init() {
        loadProfiles()
    }

    func loadProfiles() {
        guard let data = defaults.data(forKey: storageKey) else {
            profiles = []
            activeProfile = nil
            return
        }
        do {
            profiles = try JSONDecoder().decode([GatewayProfile].self, from: data)
            profiles.sort { $0.createdAt < $1.createdAt }
            activeProfile = profiles.first(where: { $0.isActive })
            AppLogger.log("[ProfileManager] Loaded \(self.profiles.count) profiles, active: \(self.activeProfile?.name ?? "none")", category: .network)
        } catch {
            AppLogger.log("[ProfileManager] Failed to decode profiles: \(error.localizedDescription)", category: .network, level: .error)
            profiles = []
            activeProfile = nil
        }
    }

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogger.log("[ProfileManager] Failed to save profiles: \(error.localizedDescription)", category: .network, level: .error)
        }
    }

    func addProfile(name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool, role: GatewayConnectionRole, enabledCaps: Set<String>) -> GatewayProfile {
        let profile = GatewayProfile(
            name: name,
            colorTag: colorTag,
            host: host,
            port: port,
            token: token,
            tlsEnabled: tlsEnabled,
            role: role,
            enabledCaps: enabledCaps
        )
        profiles.append(profile)
        saveProfiles()
        AppLogger.log("[ProfileManager] Added profile: \(name)", category: .network)
        return profile
    }

    func updateProfile(id: UUID, name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool, role: GatewayConnectionRole, enabledCaps: Set<String>) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        profiles[index].colorTag = colorTag
        profiles[index].host = host
        profiles[index].port = port
        profiles[index].token = token
        profiles[index].tlsEnabled = tlsEnabled
        profiles[index].role = role
        profiles[index].enabledCaps = enabledCaps
        profiles[index].updatedAt = Date()
        saveProfiles()
    }

    func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = profiles[index].isActive
        profiles.remove(at: index)
        saveProfiles()
        if wasActive {
            activeProfile = profiles.first
            if let active = activeProfile {
                activateProfile(active)
            }
        }
    }

    func activateProfile(_ profile: GatewayProfile?) {
        for i in profiles.indices {
            profiles[i].isActive = false
        }
        if let profile = profile, let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index].isActive = true
        }
        activeProfile = profile
        saveProfiles()
        AppLogger.log("[ProfileManager] Activated profile: \(profile?.name ?? "none")", category: .network)
    }

    func switchToProfile(_ profile: GatewayProfile) async {
        // Cancel any in-flight connect attempt before doing anything else.
        // Without this, a connect that's still in progress would race
        // with the new connect and could leave the new profile in a
        // half-connected state when the old task finally lands.
        await SessionManager.shared.cancelInFlight()
        let wasConnected = await SessionManager.shared.connectionStatus
        if wasConnected {
            await SessionManager.shared.disconnect()
        }
        activateProfile(profile)
        do {
            try await SessionManager.shared.connectWithProfile(profile)
            AppLogger.log("[ProfileManager] Connected to profile: \(profile.name)", category: .network)
        } catch {
            AppLogger.log("[ProfileManager] Failed to connect: \(error.localizedDescription)", category: .network, level: .error)
        }
    }

    func getProfile(id: UUID) -> GatewayProfile? {
        profiles.first(where: { $0.id == id })
    }
}
