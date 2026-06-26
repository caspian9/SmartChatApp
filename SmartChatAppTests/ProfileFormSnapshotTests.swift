import XCTest
@testable import SmartChatApp
import OpenClawKit

/// Pins the snapshot equality semantics and the
/// `hasUnsavedChanges` decision used by `EditProfileSheet` to
/// gate the Save / Don't Save / Cancel alert (issue #29).
final class ProfileFormSnapshotTests: XCTestCase {

    // MARK: - Empty baseline

    func test_empty_matchesNewProfileDefaults() {
        // The @State defaults in EditProfileSheet for a new profile
        // are: name="", colorTag="#10A37F", host="", port=443,
        // token="", tlsEnabled=true, role=.operatorAndNode,
        // enabledCaps=[].
        let empty = ProfileFormSnapshot.empty
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.colorTag, "#10A37F")
        XCTAssertEqual(empty.host, "")
        XCTAssertEqual(empty.port, 443)
        XCTAssertEqual(empty.token, "")
        XCTAssertTrue(empty.tlsEnabled)
        XCTAssertEqual(empty.role, .operatorAndNode)
        XCTAssertTrue(empty.enabledCaps.isEmpty)
    }

    // MARK: - GatewayProfile roundtrip

    func test_initFromGatewayProfile_roundtripsAllFields() {
        let profile = makeProfile(
            name: "prod",
            colorTag: "#3B82F6",
            host: "gateway.example.com",
            port: 8443,
            token: "tok-abc",
            tlsEnabled: false,
            role: .nodeOnly,
            enabledCaps: ["location", "screen"]
        )
        let snap = ProfileFormSnapshot(from: profile)
        XCTAssertEqual(snap.name, "prod")
        XCTAssertEqual(snap.colorTag, "#3B82F6")
        XCTAssertEqual(snap.host, "gateway.example.com")
        XCTAssertEqual(snap.port, 8443)
        XCTAssertEqual(snap.token, "tok-abc")
        XCTAssertFalse(snap.tlsEnabled)
        XCTAssertEqual(snap.role, .nodeOnly)
        XCTAssertEqual(snap.enabledCaps, ["location", "screen"])
    }

    // MARK: - Equality

    func test_equality_sameFields_isTrue() {
        let a = ProfileFormSnapshot(
            name: "x", colorTag: "#10A37F", host: "h", port: 443,
            token: "t", tlsEnabled: true,
            role: .operatorAndNode, enabledCaps: ["location"]
        )
        let b = ProfileFormSnapshot(
            name: "x", colorTag: "#10A37F", host: "h", port: 443,
            token: "t", tlsEnabled: true,
            role: .operatorAndNode, enabledCaps: ["location"]
        )
        XCTAssertEqual(a, b)
    }

    func test_inequality_differsInAnyField_isTrue() {
        let base = ProfileFormSnapshot(
            name: "x", colorTag: "#10A37F", host: "h", port: 443,
            token: "t", tlsEnabled: true,
            role: .operatorAndNode, enabledCaps: []
        )
        // Eight fields, eight single-point mutations.
        XCTAssertNotEqual(base.copy(name: "y"), base)
        XCTAssertNotEqual(base.copy(colorTag: "#FF0000"), base)
        XCTAssertNotEqual(base.copy(host: "h2"), base)
        XCTAssertNotEqual(base.copy(port: 80), base)
        XCTAssertNotEqual(base.copy(token: "t2"), base)
        XCTAssertNotEqual(base.copy(tlsEnabled: false), base)
        XCTAssertNotEqual(base.copy(role: .nodeOnly), base)
        XCTAssertNotEqual(base.copy(enabledCaps: ["location"]), base)
    }

    // MARK: - hasUnsavedChanges truth table

    func test_hasUnsavedChanges_nilOriginal_emptyCurrent_isFalse() {
        // New profile, no edits typed yet.
        XCTAssertFalse(
            ProfileFormSnapshot.hasUnsavedChanges(
                original: nil, current: .empty
            )
        )
    }

    func test_hasUnsavedChanges_nilOriginal_typedName_isTrue() {
        // New profile, user typed a name but nothing else.
        var current = ProfileFormSnapshot.empty
        current.name = "staging"
        XCTAssertTrue(
            ProfileFormSnapshot.hasUnsavedChanges(
                original: nil, current: current
            )
        )
    }

    func test_hasUnsavedChanges_originalProvided_currentMatches_isFalse() {
        // Existing profile, user opened but didn't change anything.
        let profile = makeProfile(name: "prod", host: "h")
        let original = ProfileFormSnapshot(from: profile)
        XCTAssertFalse(
            ProfileFormSnapshot.hasUnsavedChanges(
                original: original, current: original
            )
        )
    }

    func test_hasUnsavedChanges_originalProvided_currentDiffers_isTrue() {
        let profile = makeProfile(name: "prod", host: "h", port: 443)
        let original = ProfileFormSnapshot(from: profile)
        var current = original
        current.port = 80
        XCTAssertTrue(
            ProfileFormSnapshot.hasUnsavedChanges(
                original: original, current: current
            )
        )
    }

    func test_hasUnsavedChanges_originalProvided_tokenChanged_isTrue() {
        // The token is a string field; editing even one char
        // should count as an edit. (Catches the case where a user
        // accidentally clears the token field and tries to dismiss.)
        let profile = makeProfile(name: "prod", token: "real-token")
        let original = ProfileFormSnapshot(from: profile)
        var current = original
        current.token = "real-toke"  // one char missing
        XCTAssertTrue(
            ProfileFormSnapshot.hasUnsavedChanges(
                original: original, current: current
            )
        )
    }

    // MARK: - Test helpers

    private func makeProfile(
        name: String = "test",
        colorTag: String = "#10A37F",
        host: String = "host",
        port: Int = 443,
        token: String = "tok",
        tlsEnabled: Bool = true,
        role: GatewayConnectionRole = .operatorAndNode,
        enabledCaps: Set<String> = []
    ) -> GatewayProfile {
        GatewayProfile(
            name: name,
            colorTag: colorTag,
            host: host,
            port: port,
            token: token,
            tlsEnabled: tlsEnabled,
            role: role,
            enabledCaps: enabledCaps
        )
    }
}

// Test-only copy helper. Mirrors the field-by-field mutation
// style used by `inequality_differsInAnyField_isTrue` so each
// assertion surfaces a single source of diff.
private extension ProfileFormSnapshot {
    func copy(
        name: String? = nil,
        colorTag: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        token: String? = nil,
        tlsEnabled: Bool? = nil,
        role: GatewayConnectionRole? = nil,
        enabledCaps: Set<String>? = nil
    ) -> ProfileFormSnapshot {
        ProfileFormSnapshot(
            name: name ?? self.name,
            colorTag: colorTag ?? self.colorTag,
            host: host ?? self.host,
            port: port ?? self.port,
            token: token ?? self.token,
            tlsEnabled: tlsEnabled ?? self.tlsEnabled,
            role: role ?? self.role,
            enabledCaps: enabledCaps ?? self.enabledCaps
        )
    }
}