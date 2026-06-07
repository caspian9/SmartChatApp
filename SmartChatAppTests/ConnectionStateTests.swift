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

    func testSetConnecting_clearsLastError() {
        let state = ConnectionState()
        state.setDisconnected(reason: "previous failure")
        XCTAssertEqual(state.lastError, "previous failure")
        state.setConnecting(role: .operator)
        XCTAssertNil(state.lastError)
    }

    func testSetConnected_clearsLastError() {
        let state = ConnectionState()
        state.setDisconnected(reason: "previous failure")
        XCTAssertEqual(state.lastError, "previous failure")
        state.setConnected(deviceName: "device")
        XCTAssertNil(state.lastError)
    }

    func testSetConnected_clearsTestState() {
        let state = ConnectionState()
        state.setTestInProgress()
        XCTAssertTrue(state.testInProgress)
        state.setConnected(deviceName: "device")
        XCTAssertFalse(state.testInProgress)
    }

    func testTestResult_roundTrip() {
        let state = ConnectionState()
        state.setTestInProgress()
        XCTAssertTrue(state.testInProgress)
        XCTAssertNil(state.testLastResult)

        state.setTestResult(.success)
        XCTAssertFalse(state.testInProgress)
        XCTAssertEqual(state.testLastResult, .success)

        state.clearTestResult()
        XCTAssertFalse(state.testInProgress)
        XCTAssertNil(state.testLastResult)
    }

    func testSetTestResult_failure_carriesReason() {
        let state = ConnectionState()
        state.setTestInProgress()
        state.setTestResult(.failure(reason: "auth failed"))
        XCTAssertFalse(state.testInProgress)
        XCTAssertEqual(state.testLastResult, .failure(reason: "auth failed"))
    }
}
