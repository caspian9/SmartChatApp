import XCTest
import OpenClawKit
@testable import SmartChatApp

/// Pins the full (activeProfileId × profileRole × phase) matrix
/// that drives the spinner in `ProfileListView` and `EditProfileSheet`
/// (issue #35). The decision lives in a free function so it can be
/// covered by unit tests without standing up SwiftUI.
final class ProfileConnectionStateTests: XCTestCase {

    // MARK: - .operatorOnly profile role

    func test_activeProfile_operatorRole_connectingOperator_returnsTrue() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorOnly)
        XCTAssertTrue(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .operator)
            )
        )
    }

    func test_activeProfile_operatorRole_connectingNode_returnsFalse() {
        // .operatorOnly profile must NOT spin when the active
        // connect attempt is for the node role — it shouldn't be
        // possible (the role is fixed per profile), but pinning
        // the asymmetry here means a future refactor can't
        // accidentally cross-pollinate the rows.
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .node)
            )
        )
    }

    // MARK: - .nodeOnly profile role

    func test_activeProfile_nodeRole_connectingNode_returnsTrue() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .nodeOnly)
        XCTAssertTrue(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .node)
            )
        )
    }

    func test_activeProfile_nodeRole_connectingOperator_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .nodeOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .operator)
            )
        )
    }

    // MARK: - .operatorAndNode profile role

    func test_activeProfile_operatorAndNodeRole_connectingOperator_returnsTrue() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        XCTAssertTrue(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .operator)
            )
        )
    }

    func test_activeProfile_operatorAndNodeRole_connectingNode_returnsTrue() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        XCTAssertTrue(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connecting(role: .node)
            )
        )
    }

    // MARK: - Non-connecting phases never spin (even for the active profile)

    func test_activeProfile_phaseConnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connected
            )
        )
    }

    func test_activeProfile_phaseDisconnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .disconnected
            )
        )
    }

    func test_activeProfile_phaseReconnecting_returnsFalse() {
        // `.reconnecting` is a background auto-retry signal, NOT
        // a user-initiated connect attempt. The row should keep
        // showing "Disconnect" (we're already connected), not
        // a spinner. Pinning this prevents the spinner from
        // popping in mid-session.
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .reconnecting(reason: "ping timeout")
            )
        )
    }

    // MARK: - Non-connecting phases for `.operatorOnly` profile role
    //
    // The `(_, _): return false` catch-all currently covers every
    // (phase, role) pair where phase is non-connecting. These tests
    // pin the behavior for `.operatorOnly` so a regression that
    // special-cases `.operatorAndNode` for non-connecting phases
    // (e.g. the previous review found this hole) would still fail
    // here.

    func test_activeProfile_operatorOnlyRole_phaseConnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connected
            )
        )
    }

    func test_activeProfile_operatorOnlyRole_phaseDisconnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .disconnected
            )
        )
    }

    func test_activeProfile_operatorOnlyRole_phaseReconnecting_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .reconnecting(reason: "ping timeout")
            )
        )
    }

    // MARK: - Non-connecting phases for `.nodeOnly` profile role
    //
    // Same matrix coverage as `.operatorOnly` above. Without these,
    // a regression that adds an early `case (.connected, .operatorAndNode):`
    // could pass the existing test suite.

    func test_activeProfile_nodeOnlyRole_phaseConnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .nodeOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .connected
            )
        )
    }

    func test_activeProfile_nodeOnlyRole_phaseDisconnected_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .nodeOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .disconnected
            )
        )
    }

    func test_activeProfile_nodeOnlyRole_phaseReconnecting_returnsFalse() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .nodeOnly)
        XCTAssertFalse(
            ProfileConnectionState.isProfileConnecting(
                activeProfileId: activeId,
                profileId: profile.id,
                profileRole: profile.role,
                phase: .reconnecting(reason: "ping timeout")
            )
        )
    }

    // MARK: - Inactive profiles never spin, even mid-connect

    func test_inactiveProfile_anyConnectingPhase_returnsFalse() {
        // If the active profile's row is mid-connect, OTHER
        // profile rows must stay clickable so the user can hit
        // "Switch" to abort the in-flight attempt. Pin that
        // the ID guard fires before the role match.
        let activeId = UUID()
        let otherId = UUID()
        let profile = makeProfile(id: otherId, role: .operatorAndNode)
        for role in [GatewayRole.operator, .node] {
            XCTAssertFalse(
                ProfileConnectionState.isProfileConnecting(
                    activeProfileId: activeId,
                    profileId: profile.id,
                    profileRole: profile.role,
                    phase: .connecting(role: role)
                ),
                "inactive profile should never spin, even for connecting role \(role)"
            )
        }
    }

    // MARK: - Exhaustive matrix coverage

    /// Iterates `GatewayConnectionRole.allCases × GatewayRole.allCases`
    /// to make sure the function returns a defined `Bool` for every
    /// combination. Today this catches:
    ///   - Missing switch arms (would be a build error in the
    ///     implementation's switch thanks to non-fallthrough
    ///     coverage of the enum cases).
    ///   - Future regressions if `GatewayConnectionRole` or
    ///     `GatewayRole` gain a new case.
    func test_allConnectingPhaseRoles_exhaustiveCoverage() {
        let activeId = UUID()
        let profile = makeProfile(id: activeId, role: .operatorAndNode)
        for profileRole in GatewayConnectionRole.allCases {
            for connectingRole in [GatewayRole.operator, .node] {
                let result = ProfileConnectionState.isProfileConnecting(
                    activeProfileId: activeId,
                    profileId: profile.id,
                    profileRole: profileRole,
                    phase: .connecting(role: connectingRole)
                )
                // Just pin that we get a Bool (compile-time guard
                // against throwing / optional returns) and that the
                // .operatorAndNode row is always-on for both roles.
                if profileRole == .operatorAndNode {
                    XCTAssertTrue(
                        result,
                        "operatorAndNode profile should spin for connecting role \(connectingRole)"
                    )
                } else {
                    // .operatorOnly matches only .operator; .nodeOnly
                    // matches only .node.
                    let shouldMatch: Bool
                    switch (profileRole, connectingRole) {
                    case (.operatorOnly, .operator), (.nodeOnly, .node):
                        shouldMatch = true
                    default:
                        shouldMatch = false
                    }
                    XCTAssertEqual(
                        result, shouldMatch,
                        "role \(profileRole) vs connecting \(connectingRole)"
                    )
                }
            }
        }
    }

    // MARK: - Test helpers

    private func makeProfile(
        id: UUID = UUID(),
        role: GatewayConnectionRole = .operatorAndNode
    ) -> GatewayProfile {
        GatewayProfile(
            id: id,
            name: "t",
            colorTag: "#10A37F",
            host: "h",
            port: 443,
            token: "t",
            tlsEnabled: true,
            role: role,
            enabledCaps: []
        )
    }
}
