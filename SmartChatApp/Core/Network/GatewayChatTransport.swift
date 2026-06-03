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
        let emptyJSON = "{\"sessionKey\": \"\(sessionKey)\"}".data(using: .utf8)!
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: emptyJSON)
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

        var params = [
            "key": sessionKey,
            "message": message,
            "idempotencyKey": idempotencyKey
        ]
        if !thinking.isEmpty {
            params["thinking"] = thinking
        }

        var jsonParts = params.map { "\"\($0.key)\": \"\($0.value)\"" }
        if !attachments.isEmpty {
            let attachmentsJSON = try JSONEncoder().encode(attachments)
            if let attachmentsStr = String(data: attachmentsJSON, encoding: .utf8) {
                jsonParts.append("\"attachments\": \(attachmentsStr)")
            }
        }

        let jsonString = "{\(jsonParts.joined(separator: ", "))}"
        _ = try await nodeSession.request(method: "sessions.send", paramsJSON: jsonString)

        let responseJSON = "{\"runId\": \"\(idempotencyKey)\", \"status\": \"started\"}"
        return try JSONDecoder().decode(OpenClawChatSendResponse.self, from: responseJSON.data(using: .utf8)!)
    }

    public func abortRun(sessionKey: String, runId: String) async throws {
        let params = "{\"key\": \"\(sessionKey)\", \"runId\": \"\(runId)\"}"
        _ = try await nodeSession.request(method: "sessions.abort", paramsJSON: params)
    }

    public func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        var params = "{}"
        if let limit {
            params = "{\"limit\": \(limit)}"
        }
        let responseData = try await nodeSession.request(method: "sessions.list", paramsJSON: params)

        let raw = try JSONDecoder().decode(ListSessionsRaw.self, from: responseData)
        return OpenClawChatSessionsListResponse(
            ts: raw.ts, path: raw.path, count: raw.count, defaults: nil, sessions: raw.sessions)
    }

    public func setSessionModel(sessionKey: String, model: String?) async throws {
        guard let model else { return }
        let params = "{\"key\": \"\(sessionKey)\", \"model\": \"\(model)\"}"
        _ = try await nodeSession.request(method: "sessions.patch", paramsJSON: params)
    }

    public func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        let params = "{\"key\": \"\(sessionKey)\", \"thinkingLevel\": \"\(thinkingLevel)\"}"
        _ = try await nodeSession.request(method: "sessions.patch", paramsJSON: params)
    }

    public func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }

    public nonisolated func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            Task {
                let events = await self.nodeSession.subscribeServerEvents()
                for await frame in events {
                    if let event = self.mapToTransportEvent(frame) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
        }
    }

    private nonisolated func mapToTransportEvent(_ frame: EventFrame) -> OpenClawChatTransportEvent? {
        switch frame.event {
        case "tick":
            return .tick
        case "seqGap":
            return .seqGap
        case "chat.event":
            if let payload = frame.payload,
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let payloadObj = try? JSONDecoder().decode(OpenClawChatEventPayload.self, from: data) {
                return .chat(payloadObj)
            }
            return nil
        case "chat.sessionMessage":
            if let payload = frame.payload,
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let payloadObj = try? JSONDecoder().decode(OpenClawSessionMessageEventPayload.self, from: data) {
                return .sessionMessage(payloadObj)
            }
            return nil
        default:
            if let payload = frame.payload,
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let payloadObj = try? JSONDecoder().decode(OpenClawAgentEventPayload.self, from: data) {
                return .agent(payloadObj)
            }
            return nil
        }
    }

    public func disconnect() async {
        await nodeSession.disconnect()
    }
}

private struct ListSessionsRaw: Decodable {
    let sessions: [OpenClawChatSessionEntry]
    let count: Int?
    let ts: Double?
    let path: String?
}
