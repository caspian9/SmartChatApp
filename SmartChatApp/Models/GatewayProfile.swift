import Foundation

struct GatewayProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorTag: String
    var host: String
    var port: Int
    var token: String
    var tlsEnabled: Bool
    var role: GatewayConnectionRole
    var cameraEnabled: Bool
    var locationEnabled: Bool
    var voiceWakeEnabled: Bool
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, colorTag, host, port, token, tlsEnabled, role
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
        cameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? false
        locationEnabled = try container.decodeIfPresent(Bool.self, forKey: .locationEnabled) ?? false
        voiceWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceWakeEnabled) ?? false
        isActive = try container.decode(Bool.self, forKey: .isActive)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
        cameraEnabled: Bool = false,
        locationEnabled: Bool = false,
        voiceWakeEnabled: Bool = false,
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
        self.cameraEnabled = cameraEnabled
        self.locationEnabled = locationEnabled
        self.voiceWakeEnabled = voiceWakeEnabled
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
