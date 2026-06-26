import Foundation
import OpenClawKit

/// Captures the eight editable fields of `EditProfileSheet` so
/// the view can detect whether the user has unsaved changes
/// (issue #29).
///
/// `Equatable` synthesis provides field-by-field comparison;
/// `hasUnsavedChanges(original:current:)` is a one-line forwarder
/// to `!=` with `nil` falling back to `.empty` for the
/// new-profile case.
///
/// File-scope (not nested in `EditProfileSheet`) so the test
/// target can reach it via `@testable import SmartChatApp`.
struct ProfileFormSnapshot: Equatable {
    var name: String
    var colorTag: String
    var host: String
    var port: Int
    var token: String
    var tlsEnabled: Bool
    var role: GatewayConnectionRole
    var enabledCaps: Set<String>

    /// Matches the `@State` defaults of `EditProfileSheet` for a
    /// new profile (no profile loaded). Used as the "baseline"
    /// for unsaved-changes detection in the new-profile path.
    static let empty = ProfileFormSnapshot(
        name: "",
        colorTag: "#10A37F",
        host: "",
        port: 443,
        token: "",
        tlsEnabled: true,
        role: .operatorAndNode,
        enabledCaps: []
    )

    init(
        name: String,
        colorTag: String,
        host: String,
        port: Int,
        token: String,
        tlsEnabled: Bool,
        role: GatewayConnectionRole,
        enabledCaps: Set<String>
    ) {
        self.name = name
        self.colorTag = colorTag
        self.host = host
        self.port = port
        self.token = token
        self.tlsEnabled = tlsEnabled
        self.role = role
        self.enabledCaps = enabledCaps
    }

    /// Build a snapshot from a loaded `GatewayProfile`. The
    /// view's `init` calls this when editing an existing
    /// profile; new profiles pass `nil` and use `.empty` as the
    /// baseline.
    init(from profile: GatewayProfile) {
        self.name = profile.name
        self.colorTag = profile.colorTag
        self.host = profile.host
        self.port = profile.port
        self.token = profile.token
        self.tlsEnabled = profile.tlsEnabled
        self.role = profile.role
        self.enabledCaps = profile.enabledCaps
    }

    /// One-line decision used by `EditProfileSheet.hasUnsavedChanges`.
    /// `original == nil` means "new profile" — fall through to
    /// `.empty` so the alert only fires on real edits, not on
    /// opening the sheet untouched.
    static func hasUnsavedChanges(
        original: ProfileFormSnapshot?,
        current: ProfileFormSnapshot
    ) -> Bool {
        current != (original ?? .empty)
    }
}