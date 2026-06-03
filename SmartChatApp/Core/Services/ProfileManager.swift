import Foundation
import SwiftData
import OSLog

private let profileLog = Logger(subsystem: "SmartChatApp", category: "ProfileManager")

@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    var modelContainer: ModelContainer?

    @Published var profiles: [GatewayProfile] = []
    @Published var activeProfile: GatewayProfile?

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
        loadProfiles()
    }

    func loadProfiles() {
        guard let context = modelContainer?.mainContext else { return }
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
        guard let context = modelContainer?.mainContext else {
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
        guard let context = modelContainer?.mainContext else { return }
        let wasActive = profile.isActive
        context.delete(profile)
        saveContext()
        loadProfiles()
        if wasActive {
            activateProfile(profiles.first)
        }
    }

    func activateProfile(_ profile: GatewayProfile?) {
        guard let context = modelContainer?.mainContext else { return }
        for p in profiles {
            p.isActive = false
        }
        profile?.isActive = true
        activeProfile = profile
        saveContext()
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

    private func saveContext() {
        guard let context = modelContainer?.mainContext else { return }
        do {
            try context.save()
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to save: \(error.localizedDescription)")
        }
    }

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
}