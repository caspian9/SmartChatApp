import XCTest
@testable import SmartChatApp

/// Unit tests for the host-validation regex used by
/// `EditProfileSheet.isValidHost`. The previous IP form
/// `((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)`
/// was flagged by CodeQL `swift/redos` (alert #1) — the
/// `[01]?[0-9][0-9]?` ambiguity combined with `{3}` and the
/// literal `\.` produced exponential backtracking on crafted
/// inputs like "0.0" repeated.
///
/// The new form uses disjoint numeric alternations
/// (25[0-5] / 2[0-4][0-9] / 1[0-9]{2} / [1-9]?[0-9]) so each
/// octet has exactly one matching path. These tests pin the
/// ReDoS-attempt inputs are rejected in O(n) — the actual
/// fix CodeQL asked for — and that the user-visible
/// behavior (legit IPs and domains still match) is
/// preserved.
///
/// `matchesHost` is a format check, not an existence check.
/// It accepts BOTH a strict IPv4 octet-range pattern AND a
/// looser domain pattern (alphanumeric labels joined by
/// dots, allowing dashes). The intent is "is this shaped
/// like a host the user might want to talk to?" — not
/// "is this a routable address?".
final class EditProfileSheetTests: XCTestCase {

    // MARK: - Valid IPv4 addresses (should match via the IP path)

    func testValidIPv4Addresses() {
        let valid = [
            "0.0.0.0",
            "1.2.3.4",
            "8.8.8.8",
            "9.9.9.9",
            "10.0.0.1",
            "100.200.50.25",
            "127.0.0.1",
            "172.16.254.1",
            "192.168.1.1",
            "255.255.255.255"
        ]
        for host in valid {
            XCTAssertTrue(
                EditProfileSheet.matchesHost(host),
                "Expected '\(host)' to be a valid host"
            )
        }
    }

    // MARK: - Valid domains (should match via the domain path)

    func testValidDomains() {
        let valid = [
            "api.example.com",
            "sub.domain.example.org",
            "my-host.example.com",
            "a.b"
        ]
        for host in valid {
            XCTAssertTrue(
                EditProfileSheet.matchesHost(host),
                "Expected '\(host)' to be a valid host"
            )
        }
    }

    // MARK: - Strings that are neither valid IP-shaped nor valid domain-shaped

    /// `localhost` is intentionally NOT in the accepted list —
    /// the domain pattern requires at least one dot (the
    /// `(\\.[a-zA-Z0-9]...)+` group must match at least once).
    /// The actual app's `cleanHost` doesn't alter "localhost",
    /// and the connection attempt downstream will surface the
    /// resolution failure to the user.
    func testHostnamesWithoutDotsAreRejected() {
        let rejected = [
            "localhost",       // no dot — domain pattern requires ≥1
            "example",         // single label
            "myhost"           // single label
        ]
        for host in rejected {
            XCTAssertFalse(
                EditProfileSheet.matchesHost(host),
                "Expected '\(host)' to be rejected (no dot, not a valid IPv4)"
            )
        }
    }

    /// IP-shaped strings with wrong octet counts are
    /// rejected — neither the strict IPv4 path (anchors to
    /// 4 octets) nor the domain path (would need a TLD
    /// that itself is a 3-digit numeric label, and even
    /// then "1.2.3" without a 4th octet is too few dots)
    /// accept them. Wait — re-check: "192.168.1" has 2 dots,
    /// domain pattern wants ≥1, each label 1+ alnum. So
    /// "192.168.1" actually IS accepted by the domain path.
    /// We document this here as known behavior; tightening
    /// the host validator is out of scope for the ReDoS fix.
    func testIPShapeWithThreeOctetsIsAcceptedAsDomain() {
        // Documenting the actual behavior: a string shaped
        // like a 3-octet IP slips through the domain path
        // because the domain pattern is looser than the IP
        // pattern. The ReDoS fix is about timing, not about
        // tightening the IP shape — that's a separate task.
        let accepted = [
            "192.168.1",        // 3 dot-separated alnum labels
            "192.168.1.1.1"     // 5 dot-separated alnum labels
        ]
        for host in accepted {
            XCTAssertTrue(
                EditProfileSheet.matchesHost(host),
                "Sanity: '\(host)' slips through the domain path"
            )
        }
    }

    // MARK: - ReDoS regression (the actual CodeQL fix)

    /// The crafted input that triggered CodeQL alert #1. With
    /// the old ambiguous form this could take seconds (or
    /// blow the regex engine's stack) on inputs of 30+
    /// "0.0" repetitions. The disjoint-ranges form completes
    /// in microseconds. We give the engine 200ms — a generous
    /// upper bound on a 2.6GHz-class simulator runner for
    /// input of 100 octets.
    func testReDoSAttemptIsFast() {
        let evil = String(repeating: "0.0", count: 50)  // 100 chars
        let t0 = Date()
        _ = EditProfileSheet.matchesHost(evil)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(
            elapsed, 0.2,
            "ReDoS regression: matchesHost took \(elapsed)s on a 100-char crafted input"
        )
    }

    /// CodeQL's specific attack example: a string starting with
    /// "0.0" and containing many repetitions of "0.0". The old
    /// regex would attempt to interpret this as 4+ octets, fail
    /// the 4-octet anchor, and on failure try alternative
    /// match paths for each octet — exponential. The new
    /// regex is bounded; we assert only on time, not on
    /// whether the host is accepted (it IS accepted as a
    /// domain — "0.0.0.0..." is a chain of valid labels).
    func testCodeQLFlaggedPatternIsFast() {
        let evil = "0.0" + String(repeating: "0.0", count: 20)
        let t0 = Date()
        _ = EditProfileSheet.matchesHost(evil)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 0.1)
    }

    // MARK: - Edge cases

    func testEmptyHostIsRejected() {
        XCTAssertFalse(EditProfileSheet.matchesHost(""))
    }
}
