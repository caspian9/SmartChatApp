import Foundation
import SwiftData

@Model
final class GatewayProfile {
    var id: UUID
    var name: String
    var colorTag: String
    var host: String
    var port: Int
    var token: String
    var tlsEnabled: Bool
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
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
