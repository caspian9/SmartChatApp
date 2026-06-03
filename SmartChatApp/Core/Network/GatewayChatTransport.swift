import Foundation
import OpenClawKit
import OpenClawProtocol
import OpenClawChatUI

public actor GatewayChatTransport: OpenClawChatTransport {
    private let nodeSession: GatewayNodeSession
    private var sessionKey: String

    public init(nodeSession: GatewayNodeSession, sessionKey: String) {
        self.nodeSession = nodeSession
        self.sessionKey = sessionKey
    }

    public func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let responseData = try await nodeSession.request(
            method: "sessions.history",
            paramsJSON: "{\"key\": \"\(sessionKey)\"}"
        )
        throw NSError(domain: "GatewayChatTransport", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "requestHistory not fully implemented"
        ])
    }

    public func listModels() async throws -> [OpenClawChatModelChoice] {
        return []
    }

    public func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        self.sessionKey = sessionKey
        throw NSError(domain: "GatewayChatTransport", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "sendMessage not fully implemented"
        ])
    }

    public func abortRun(sessionKey: String, runId: String) async throws {
        throw NSError(domain: "GatewayChatTransport", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "abortRun not fully implemented"
        ])
    }

    public func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw NSError(domain: "GatewayChatTransport", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "listSessions not fully implemented"
        ])
    }

    public func setSessionModel(sessionKey: String, model: String?) async throws {
    }

    public func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
    }

    public func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }

    public nonisolated func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            Task {
                continuation.finish()
            }
        }
    }

    public func disconnect() async {
        await nodeSession.disconnect()
    }
}
