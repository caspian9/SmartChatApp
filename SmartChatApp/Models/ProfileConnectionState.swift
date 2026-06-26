import Foundation
import OpenClawKit

/// Pure decision: should this profile row show the connecting spinner?
/// Extracted from `ProfileListView.isProfileConnecting(_:)` so the
/// full (activeProfileId × profileRole × phase) matrix can be
/// covered by unit tests without standing up SwiftUI (issue #35).
///
/// File-scope (not nested in `ProfileListView`) so the test target
/// can reach it via `@testable import SmartChatApp`. Mirrors the
/// `EditProfileSheet.matchesHost` and `ProfileFormSnapshot`
/// precedents for testing without ViewInspector.
enum ProfileConnectionState {
    /// True iff:
    ///   1. `activeProfileId == profileId` (the row IS the active profile — non-active rows must never spin), AND
    ///   2. The connection phase is `.connecting(role:)` with a role
    ///      matching the profile's `role` field:
    ///      - `.operatorOnly` profile matches `.operator` connecting phase
    ///      - `.nodeOnly` profile matches `.node` connecting phase
    ///      - `.operatorAndNode` matches either role
    /// All other phases (.connected, .disconnected, .reconnecting)
    /// return false — the row should show "Connect" or "Disconnect",
    /// not a spinner.
    static func isProfileConnecting(
        activeProfileId: UUID?,
        profileId: UUID,
        profileRole: GatewayConnectionRole,
        phase: ConnectionState.Phase
    ) -> Bool {
        guard activeProfileId == profileId else { return false }
        switch (phase, profileRole) {
        case (.connecting(let connectingRole), .operatorOnly):
            return connectingRole == .`operator`
        case (.connecting(let connectingRole), .nodeOnly):
            return connectingRole == .node
        case (.connecting(let connectingRole), .operatorAndNode):
            return connectingRole == .`operator` || connectingRole == .node
        case (.connecting, _), (_, _):
            return false
        }
    }
}