import Foundation

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var toolCalls: [ToolCall]?
    let createdAt: Date

    init(id: String = UUID().uuidString, role: MessageRole, content: String, toolCalls: [ToolCall]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }
}

struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let arguments: String
    var result: String?

    init(id: String = UUID().uuidString, name: String, arguments: String, result: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
    }
}

struct ChatSession: Identifiable, Equatable {
    let id: String
    var title: String
    var messages: [Message]
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String = "New Chat", messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
