import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI
import UIKit
import SwiftData

public struct DebugLogEntry: Identifiable, Equatable {
    public var id = UUID()
    public var ts: Date
    public var message: String
    public var category: String

    public init(id: UUID = UUID(), ts: Date, message: String, category: String) {
        self.id = id
        self.ts = ts
        self.message = message
        self.category = category
    }
}

/// Thin forwarder to `ConnectionCoordinator`.
///
/// Preserved public API so existing callers (`ProfileManager`,
/// `ProfileListView`, `EditProfileSheet`, `ChatListView`, `HomeView`,
/// `NativeChatViewModel`, `App/SmartChatAppApp`, `SettingsView`,
/// `DiscoveryLogsView`) keep working. All connection-management logic
/// lives in `ConnectionCoordinator`; this class is a compatibility shim
/// that will be removed once all callers migrate to read `ConnectionState`
/// directly (Tasks 9-11).
actor SessionManager {
    static let shared = SessionManager()
    private let coordinator = ConnectionCoordinator.shared

    // Preserved state (used by `makeTransport` for the current-key side
    // effect and by debug UI; not all of it is forwarded to the
    // coordinator yet).
    private var currentSessionKey: String?
    private var debugLoggingEnabled = false
    private var discoveryDebugLoggingEnabled = false
    private var debugLog: [DebugLogEntry] = []
    private var reconnectOnLaunch = false

    private init() {}

    // MARK: - Read-only state (kept as `var`, not `func`, to preserve
    // the existing public shape — callers already `await` actor-isolated
    // accessors and adding parens would force ~10 call sites to recompile.)

    var connectionStatus: Bool { operatorConnected }
    var operatorConnectionStatus: Bool { operatorConnected }
    var nodeConnectionStatus: Bool { nodeConnected }
    var nodeConnectionErrorMessage: String? { nil }
    var deviceName: String? { connectedDeviceName }

    // Local mirror of the coordinator's connected flags, so the var
    // accessors above can return without bouncing through the coordinator.
    // Updated in `connect`/`disconnect` below.
    private var operatorConnected = false
    private var nodeConnected = false
    private var connectedDeviceName: String?

    // MARK: - Connect / disconnect

    func connectWithRole(
        gatewayURL: URL,
        authToken: String,
        role: GatewayConnectionRole,
        enabledCaps: Set<String>
    ) async throws {
        try await coordinator.connectWithRole(
            gatewayURL: gatewayURL,
            authToken: authToken,
            role: role,
            enabledCaps: enabledCaps
        )
        switch role {
        case .operatorOnly:
            operatorConnected = await coordinator.connectionStatus
        case .nodeOnly:
            nodeConnected = await coordinator.nodeConnectionStatus
        case .operatorAndNode:
            operatorConnected = await coordinator.connectionStatus
            nodeConnected = await coordinator.nodeConnectionStatus
        }
    }

    func connectWithProfile(_ profile: GatewayProfile) async throws {
        try await coordinator.connectWithProfile(profile)
        operatorConnected = await coordinator.connectionStatus
        nodeConnected = await coordinator.nodeConnectionStatus
        connectedDeviceName = await coordinator.deviceName
    }

    func gatewayURL(host: String, port: Int, tlsEnabled: Bool) -> URL {
        coordinator.gatewayURL(host: host, port: port, tlsEnabled: tlsEnabled)
    }

    func connect(gatewayURL: URL, authToken: String) async throws {
        try await connectWithRole(
            gatewayURL: gatewayURL,
            authToken: authToken,
            role: .operatorOnly,
            enabledCaps: []
        )
    }

    func connectNodeRole(
        gatewayURL: URL,
        authToken: String,
        enabledCaps: Set<String>
    ) async throws {
        try await coordinator.connectWithRole(
            gatewayURL: gatewayURL,
            authToken: authToken,
            role: .nodeOnly,
            enabledCaps: enabledCaps
        )
        nodeConnected = await coordinator.nodeConnectionStatus
    }

    func ensureConnected() async throws {
        let activeProfile = await MainActor.run { ProfileManager.shared.activeProfile }
        guard let profile = activeProfile else {
            AppLogger.log("No active profile available", category: .network)
            return
        }
        try await coordinator.ensureConnected(profile: profile)
        operatorConnected = await coordinator.connectionStatus
        nodeConnected = await coordinator.nodeConnectionStatus
        connectedDeviceName = await coordinator.deviceName
    }

    func reconnect() async throws {
        await coordinator.disconnect()
        try await ensureConnected()
    }

    func disconnect() async {
        await coordinator.disconnect()
        operatorConnected = false
        nodeConnected = false
        connectedDeviceName = nil
    }

    /// Test-only connect: probes a profile's connectivity without
    /// disturbing the main `ConnectionState.phase`. The caller (e.g.
    /// `EditProfileSheet`'s "Test Connection" button) reads
    /// `ConnectionState.testInProgress` / `testLastResult` to surface
    /// the outcome.
    func testConnect(
        gatewayURL: URL,
        authToken: String,
        role: GatewayConnectionRole,
        enabledCaps: Set<String>
    ) async throws {
        try await coordinator.testConnect(
            gatewayURL: gatewayURL,
            authToken: authToken,
            role: role,
            enabledCaps: enabledCaps
        )
    }

    /// Cancel any in-flight connect attempts. The existing transport
    /// (if any) is left alive. Used by `ProfileManager.switchToProfile`
    /// to abort a connect attempt when the user changes their mind and
    /// switches to a different profile.
    func cancelInFlight() async {
        await coordinator.cancelInFlight()
    }

    func checkConnection() async -> Bool {
        let isConnected = await coordinator.connectionStatus
        if !isConnected {
            do {
                try await ensureConnected()
            } catch {
                return false
            }
        }
        return await coordinator.connectionStatus
    }

    // MARK: - Session

    func createSession(agentId: String? = nil, customKey: String? = nil) async throws -> String {
        try await coordinator.createSession(agentId: agentId, customKey: customKey)
    }

    /// Returns a cached `any OpenClawChatTransport` for `sessionKey`.
    /// Side effect: stores `sessionKey` in `currentSessionKey` so
    /// `getCurrentSessionKey()` can return it. This was the existing
    /// contract; the coordinator's cache makes the actor identity stable
    /// across calls.
    func makeTransport(sessionKey: String) async -> any OpenClawChatTransport {
        currentSessionKey = sessionKey
        return await coordinator.getTransport(sessionKey: sessionKey)
    }

    func getCurrentSessionKey() -> String? { currentSessionKey }

    /// Fetch the latest history for `sessionKey` from the gateway via `chat.history`
    /// (limit=100, maxChars=100000). The transport is provided by
    /// `makeTransport(sessionKey:)`; `GatewayChatTransport` falls back to
    /// `MessageCacheStore` on failure. Side effect: updates `currentSessionKey`
    /// via `makeTransport` — callers should snapshot/restore via
    /// `getCurrentSessionKey()` if calling outside the active chat.
    func refreshMessages(for sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let transport = await makeTransport(sessionKey: sessionKey)
        return try await transport.requestHistory(sessionKey: sessionKey)
    }

    // MARK: - Reconnect-on-launch flag (preserved for `App.swift`)

    func setReconnectOnLaunch(_ value: Bool) { reconnectOnLaunch = value }
    var shouldReconnectOnLaunch: Bool { reconnectOnLaunch }

    // MARK: - Debug logging (kept here for now; could move later)

    func setDebugLoggingEnabled(_ enabled: Bool) { debugLoggingEnabled = enabled }
    func setDiscoveryDebugLoggingEnabled(_ enabled: Bool) { discoveryDebugLoggingEnabled = enabled }
    func getDebugLogs() -> [DebugLogEntry] { debugLog }
    func clearDebugLogs() { debugLog.removeAll() }
}

enum SessionManagerError: Error, LocalizedError {
    case notConnected
    case invalidResponse
    case authError(String, String?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to gateway"
        case .invalidResponse:
            return "Invalid server response"
        case .authError(let message, _):
            return message
        }
    }
}
