import Foundation
import OpenClawKit

struct GatewayProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorTag: String
    var host: String
    var port: Int
    var token: String
    var tlsEnabled: Bool
    var role: GatewayConnectionRole
    var enabledCaps: Set<String>
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, colorTag, host, port, token, tlsEnabled, role
        case enabledCaps
        case cameraEnabled, locationEnabled, voiceWakeEnabled
        case isActive, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorTag = try container.decode(String.self, forKey: .colorTag)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        token = try container.decode(String.self, forKey: .token)
        tlsEnabled = try container.decode(Bool.self, forKey: .tlsEnabled)
        role = try container.decode(GatewayConnectionRole.self, forKey: .role)
        if let stored = try container.decodeIfPresent(Set<String>.self, forKey: .enabledCaps) {
            enabledCaps = stored
        } else {
            // Migrate pre-Set profiles that stored per-cap bools.
            var migrated: Set<String> = []
            if try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? false {
                migrated.insert(OpenClawCapability.camera.rawValue)
            }
            if try container.decodeIfPresent(Bool.self, forKey: .locationEnabled) ?? false {
                migrated.insert(OpenClawCapability.location.rawValue)
            }
            if try container.decodeIfPresent(Bool.self, forKey: .voiceWakeEnabled) ?? false {
                migrated.insert(OpenClawCapability.voiceWake.rawValue)
            }
            enabledCaps = migrated
        }
        isActive = try container.decode(Bool.self, forKey: .isActive)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        // Only the canonical fields are written. The legacy per-cap bools exist
        // solely so old profiles (pre-Set) decode cleanly into enabledCaps.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(colorTag, forKey: .colorTag)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(token, forKey: .token)
        try container.encode(tlsEnabled, forKey: .tlsEnabled)
        try container.encode(role, forKey: .role)
        try container.encode(enabledCaps, forKey: .enabledCaps)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    init(
        id: UUID = UUID(),
        name: String,
        colorTag: String = "#10A37F",
        host: String,
        port: Int = 443,
        token: String,
        tlsEnabled: Bool = true,
        role: GatewayConnectionRole = .operatorAndNode,
        enabledCaps: Set<String> = [],
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorTag = colorTag
        self.host = host
        self.port = port
        self.token = token
        self.tlsEnabled = tlsEnabled
        self.role = role
        self.enabledCaps = enabledCaps
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
