import Foundation
import OSLog

private let profileLog = Logger(subsystem: "SmartChatApp", category: "ProfileManager")

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
            profileLog.log("SMAlog: [ProfileManager] Loaded \(self.profiles.count) profiles, active: \(self.activeProfile?.name ?? "none")")
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to decode profiles: \(error.localizedDescription)")
            profiles = []
            activeProfile = nil
        }
    }

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: storageKey)
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to save profiles: \(error.localizedDescription)")
        }
    }

    func addProfile(name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool, role: GatewayConnectionRole) -> GatewayProfile {
        let profile = GatewayProfile(
            name: name,
            colorTag: colorTag,
            host: host,
            port: port,
            token: token,
            tlsEnabled: tlsEnabled,
            role: role
        )
        profiles.append(profile)
        saveProfiles()
        profileLog.log("SMAlog: [ProfileManager] Added profile: \(name)")
        return profile
    }

    func updateProfile(id: UUID, name: String, colorTag: String, host: String, port: Int, token: String, tlsEnabled: Bool, role: GatewayConnectionRole) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        profiles[index].colorTag = colorTag
        profiles[index].host = host
        profiles[index].port = port
        profiles[index].token = token
        profiles[index].tlsEnabled = tlsEnabled
        profiles[index].role = role
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
        profileLog.log("SMAlog: [ProfileManager] Activated profile: \(profile?.name ?? "none")")
    }

    func switchToProfile(_ profile: GatewayProfile) async {
        let wasConnected = await SessionManager.shared.connectionStatus
        if wasConnected {
            await SessionManager.shared.disconnect()
        }
        activateProfile(profile)
        do {
            try await SessionManager.shared.connectWithProfile(profile)
            profileLog.log("SMAlog: [ProfileManager] Connected to profile: \(profile.name)")
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to connect: \(error.localizedDescription)")
        }
    }

    func getProfile(id: UUID) -> GatewayProfile? {
        profiles.first(where: { $0.id == id })
    }
}
