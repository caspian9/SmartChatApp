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
