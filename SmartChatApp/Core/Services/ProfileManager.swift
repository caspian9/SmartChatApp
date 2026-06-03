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
            profileLog.log("SMAlog: [ProfileManager] Failed to setup container: \(error.localizedDescription)")
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
        if await SessionManager.shared.connectionStatus {
            await SessionManager.shared.disconnect()
        }
        activateProfile(profile)
        do {
            try await SessionManager.shared.connectWithProfile(profile)
        } catch {
            profileLog.log("SMAlog: [ProfileManager] Failed to connect: \(error.localizedDescription)")
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
