import Foundation
import Observation

enum GatewayRole: String, Sendable {
    case `operator`
    case node
}

@MainActor
@Observable
final class ConnectionState {
    enum Phase: Equatable {
        case disconnected
        case connecting(role: GatewayRole)
        case connected
        case reconnecting(reason: String)
    }

    private(set) var phase: Phase = .disconnected
    private(set) var connectedDeviceName: String?
    private(set) var lastError: String?
    private(set) var reconnectAttempts: Int = 0

    static let shared = ConnectionState()

    func setConnecting(role: GatewayRole) {
        phase = .connecting(role: role)
    }

    func setConnected(deviceName: String?) {
        phase = .connected
        connectedDeviceName = deviceName
        lastError = nil
        reconnectAttempts = 0
    }

    func setDisconnected(reason: String?) {
        phase = .disconnected
        connectedDeviceName = nil
        lastError = reason
    }

    func setReconnecting(reason: String) {
        phase = .reconnecting(reason: reason)
        reconnectAttempts += 1
    }
}
