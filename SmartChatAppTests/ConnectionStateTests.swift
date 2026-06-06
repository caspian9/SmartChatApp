import XCTest
@testable import SmartChatApp

@MainActor
final class ConnectionStateTests: XCTestCase {
    func testInitialPhaseIsDisconnected() {
        let state = ConnectionState()
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.connectedDeviceName)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.reconnectAttempts, 0)
    }

    func testSetConnectedUpdatesPhaseAndDeviceName() {
        let state = ConnectionState()
        state.setConnected(deviceName: "test-device")
        XCTAssertEqual(state.phase, .connected)
        XCTAssertEqual(state.connectedDeviceName, "test-device")
    }

    func testSetDisconnectedClearsDeviceNameAndSetsReason() {
        let state = ConnectionState()
        state.setConnected(deviceName: "test-device")
        state.setDisconnected(reason: "test reason")
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.connectedDeviceName)
        XCTAssertEqual(state.lastError, "test reason")
    }

    func testSetReconnectingIncrementsAttempts() {
        let state = ConnectionState()
        state.setReconnecting(reason: "network")
        XCTAssertEqual(state.phase, .reconnecting(reason: "network"))
        XCTAssertEqual(state.reconnectAttempts, 1)
        state.setReconnecting(reason: "network")
        XCTAssertEqual(state.reconnectAttempts, 2)
    }

    func testSetReconnectingThenConnectedResetsAttempts() {
        let state = ConnectionState()
        state.setReconnecting(reason: "network")
        state.setConnected(deviceName: "device")
        XCTAssertEqual(state.phase, .connected)
        XCTAssertEqual(state.reconnectAttempts, 0)
    }
}
