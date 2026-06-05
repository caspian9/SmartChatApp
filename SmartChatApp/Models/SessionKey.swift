import Foundation

struct SessionKey: Equatable {
    let raw: String
    let agentId: String?
    let channel: String?
    let label: String?
    let uuid: String?

    static func parse(_ raw: String) -> SessionKey {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        func segment(_ i: Int) -> String? {
            guard i < parts.count else { return nil }
            let s = String(parts[i]).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        let label = segment(3)
        let explicitUuid = segment(4)
        let hasFourthSegment = parts.count > 3
        // uuid resolution:
        //  1. explicit 5th segment (when present) wins — this is the "real" uuid
        //  2. otherwise, if a 4th segment exists and is non-empty, it doubles as
        //     both label and uuid (preserves the existing VM collision behavior)
        //  3. otherwise (no 4th segment at all), fall back to last 8 chars of raw
        //     (matches NativeChatViewModel.extractSessionUuid fallback)
        //  4. if a 4th segment was present but empty, uuid is nil
        let uuid: String? = {
            if let explicitUuid { return explicitUuid }
            if let label { return label }
            if !hasFourthSegment { return String(raw.suffix(8)) }
            return nil
        }()
        return SessionKey(
            raw: raw,
            agentId: segment(1),
            channel: segment(2),
            label: label,
            uuid: uuid
        )
    }

    /// Build a new session key for createSession: "agent:<agentId>:<clientLabel>:<uuid>".
    static func makeNew(agentId: String, clientLabel: String) -> String {
        "agent:\(agentId):\(clientLabel):\(UUID().uuidString.lowercased())"
    }
}
