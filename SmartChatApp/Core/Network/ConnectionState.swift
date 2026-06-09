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

    enum TestResult: Equatable {
        case success
        case failure(reason: String)
    }

    private(set) var phase: Phase = .disconnected
    private(set) var connectedDeviceName: String?
    private(set) var lastError: String?
    private(set) var reconnectAttempts: Int = 0
    private(set) var testInProgress: Bool = false
    private(set) var testLastResult: TestResult? = nil

    static let shared = ConnectionState()

    func setConnecting(role: GatewayRole) {
        print("[DEBUG] setConnecting role=\(role.rawValue) before phase=\(phase)")
        phase = .connecting(role: role)
        lastError = nil
    }

    func setConnected(deviceName: String?) {
        print("[DEBUG] setConnected device=\(deviceName ?? "nil") before phase=\(phase)")
        phase = .connected
        connectedDeviceName = deviceName
        lastError = nil
        reconnectAttempts = 0
        testInProgress = false
        testLastResult = nil
    }

    func setDisconnected(reason: String?) {
        print("[DEBUG] setDisconnected reason=\(reason ?? "nil") before phase=\(phase)")
        phase = .disconnected
        connectedDeviceName = nil
        lastError = reason
    }

    func setReconnecting(reason: String) {
        print("[DEBUG] setReconnecting reason=\(reason) before phase=\(phase)")
        phase = .reconnecting(reason: reason)
        reconnectAttempts += 1
        print("[DEBUG] setReconnecting after phase=\(phase)")
    }

    func setTestInProgress() {
        testInProgress = true
        testLastResult = nil
    }

    func setTestResult(_ result: TestResult) {
        testInProgress = false
        testLastResult = result
    }

    func clearTestResult() {
        testInProgress = false
        testLastResult = nil
    }
}
