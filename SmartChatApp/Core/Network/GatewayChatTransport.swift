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

        struct HistoryResponse: Decodable {
            let key: String
            let id: String?
            let messages: [AnyCodable]?
            let thinkingLevel: String?
        }

        guard let response = try? JSONDecoder().decode(HistoryResponse.self, from: responseData) else {
            throw NSError(domain: "GatewayChatTransport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode history response"
            ])
        }

        return OpenClawChatHistoryPayload(
            sessionKey: response.key,
            sessionId: response.id,
            messages: response.messages,
            thinkingLevel: response.thinkingLevel
        )
    }

    public func listModels() async throws -> [OpenClawChatModelChoice] {
        let responseData = try await nodeSession.request(
            method: "models.list",
            paramsJSON: nil
        )

        struct ModelsListResponse: Decodable {
            let models: [OpenClawChatModelChoice]
        }

        guard let response = try? JSONDecoder().decode(ModelsListResponse.self, from: responseData) else {
            return []
        }

        return response.models
    }

    public func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        self.sessionKey = sessionKey

        let params = """
        {"key": "\(sessionKey)", "message": "\(message.replacingOccurrences(of: "\"", with: "\\\""))", "thinking": "\(thinking)", "idempotencyKey": "\(idempotencyKey)"}
        """

        let responseData = try await nodeSession.request(
            method: "chat.send",
            paramsJSON: params
        )

        struct SendResponse: Decodable {
            let runId: String
            let status: String
        }

        guard let response = try? JSONDecoder().decode(SendResponse.self, from: responseData) else {
            throw NSError(domain: "GatewayChatTransport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode send response"
            ])
        }

        return OpenClawChatSendResponse(runId: response.runId, status: response.status)
    }

    public func abortRun(sessionKey: String, runId: String) async throws {
        let params = """
        {"key": "\(sessionKey)", "runId": "\(runId)"}
        """

        _ = try await nodeSession.request(
            method: "chat.abort",
            paramsJSON: params
        )
    }

    public func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        var params = "{}"
        if let limit = limit {
            params = "{\"limit\": \(limit)}"
        }

        let responseData = try await nodeSession.request(
            method: "sessions.list",
            paramsJSON: params
        )

        struct SessionsListResponse: Decodable {
            let sessions: [OpenClawChatSessionEntry]
        }

        guard let response = try? JSONDecoder().decode(SessionsListResponse.self, from: responseData) else {
            return OpenClawChatSessionsListResponse(sessions: [], ts: 0)
        }

        return OpenClawChatSessionsListResponse(sessions: response.sessions, ts: Int(Date().timeIntervalSince1970))
    }

    public func setSessionModel(sessionKey: String, model: String?) async throws {
        let params = model != nil
            ? "{\"key\": \"\(sessionKey)\", \"model\": \"\(model!)\"}"
            : "{\"key\": \"\(sessionKey)\"}"

        _ = try await nodeSession.request(
            method: "sessions.patch",
            paramsJSON: params
        )
    }

    public func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        let params = """
        {"key": "\(sessionKey)", "thinkingLevel": "\(thinkingLevel)"}
        """

        _ = try await nodeSession.request(
            method: "sessions.patch",
            paramsJSON: params
        )
    }

    public func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }

    public func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            Task {
                let events = self.nodeSession.subscribeServerEvents()
                for await event in events {
                    if event.type == "health" {
                        continuation.yield(.health(ok: true))
                    } else if event.type == "response" || event.type == "event" {
                        let payload = OpenClawChatEventPayload(
                            runId: nil,
                            sessionKey: self.sessionKey,
                            state: event.type,
                            message: nil,
                            errorMessage: nil
                        )
                        continuation.yield(.chat(payload))
                    }
                }
                continuation.finish()
            }
        }
    }
}
