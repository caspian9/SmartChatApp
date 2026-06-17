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
        do {
            let params = "{\"sessionKey\": \"\(sessionKey)\", \"limit\": 200, \"maxChars\": 100000}"
            let responseData = try await nodeSession.request(
                method: "chat.history",
                paramsJSON: params
            )
            let payload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: responseData)

            // Note: Messages are appended to MessageCacheStore by NativeChatViewModel after
            // transforming/deduplicating per the network payload.
            return payload
        } catch {
            AppLogger.log("requestHistory failed: \(error)", category: .network)
            let cached = await MessageCacheStore.shared.messages(for: sessionKey)
            if !cached.isEmpty {
                let messagesAny: [AnyCodable] = cached.map { AnyCodable($0) }
                let jsonStr = "{\"sessionKey\": \"\(sessionKey)\", \"messages\": \(messagesAny)}"
                if let data = jsonStr.data(using: .utf8),
                   let result = try? JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data) {
                    return result
                }
            }
            return payloadWithEmptyMessages(sessionKey: sessionKey)
        }
    }

    private func payloadWithEmptyMessages(sessionKey: String) -> OpenClawChatHistoryPayload {
        let jsonStr = "{\"sessionKey\": \"\(sessionKey)\", \"messages\": []}"
        if let data = jsonStr.data(using: .utf8),
           let result = try? JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data) {
            return result
        }
        fatalError("Cannot create empty history payload")
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

        struct SendParams: Encodable {
            let key: String
            let message: String
            let thinking: String?
            let idempotencyKey: String
            let attachments: [OpenClawChatAttachmentPayload]?
        }

        let params = SendParams(
            key: sessionKey,
            message: message,
            thinking: thinking.isEmpty ? nil : thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments.isEmpty ? nil : attachments
        )

        let paramsData = try JSONEncoder().encode(params)
        let paramsJSON = String(data: paramsData, encoding: .utf8)
        _ = try await nodeSession.request(method: "sessions.send", paramsJSON: paramsJSON)

        let userMessage = OpenClawChatMessage(
            role: "user",
            content: [OpenClawChatMessageContent(
                type: "text",
                text: message,
                thinking: nil,
                thinkingSignature: nil,
                mimeType: nil,
                fileName: nil,
                content: nil,
                id: nil,
                name: nil,
                arguments: nil)],
            timestamp: Date().timeIntervalSince1970 * 1000,
            toolCallId: nil,
            toolName: nil,
            usage: nil,
            stopReason: nil
        )
        await MessageCacheStore.shared.append([userMessage], for: sessionKey)

        let responseJSON = "{\"runId\": \"\(idempotencyKey)\", \"status\": \"started\"}"
        return try JSONDecoder().decode(OpenClawChatSendResponse.self, from: responseJSON.data(using: .utf8)!)
    }

    public func appendUserMessage(_ message: OpenClawChatMessage, for sessionKey: String) async {
        await MessageCacheStore.shared.append([message], for: sessionKey)
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
        // Map "off" → "off" gate, anything else → "stream" gate so the
        // server actually emits stream=thinking events. Without
        // reasoningLevel set to "stream",
        // subscribeEmbeddedAgentSession:172 short-circuits and the client
        // never receives thinking content even when the provider emits
        // reasoning blocks.
        let serverGate = (thinkingLevel == "off") ? "off" : "stream"
        let params = """
        {"key": "\(sessionKey)", "thinkingLevel": "\(thinkingLevel)", "reasoningLevel": "\(serverGate)"}
        """
        // DIAG: temporary dump of the wire payload + the server's reply,
        // scoped to the .network category (toggle in Settings → Debug &
        // Logs). Will be removed once we confirm the chain end-to-end.
        let responseData = try await nodeSession.request(method: "sessions.patch", paramsJSON: params)
        AppLogger.log(
            "setSessionThinking ok - sessionKey=\(sessionKey) thinkingLevel=\(thinkingLevel) reasoningLevel=\(serverGate) response=\(String(data: responseData, encoding: .utf8) ?? "<binary>")",
            category: .network
        )
    }

    public func requestHealth(timeoutMs: Int) async throws -> Bool {
        return true
    }

    public nonisolated func events() -> AsyncStream<OpenClawChatTransportEvent> {
        let nodeSession = nodeSession
        return AsyncStream { continuation in
            let task = Task {
                let events = await nodeSession.subscribeServerEvents()
                for await frame in events {
                    AppLogger.log("frame received: event=\(frame.event)", category: .network)
                    if let event = mapToTransportEventStatic(frame) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private nonisolated func mapToTransportEventStatic(_ frame: EventFrame) -> OpenClawChatTransportEvent? {
        switch frame.event {
        case "tick":
            return .tick
        case "seqGap":
            return .seqGap
        case "chat", "chat.event":
            if let payload = frame.payload {
                let decoded = try? GatewayPayloadDecoding.decode(payload, as: OpenClawChatEventPayload.self)
                if let payloadObj = decoded {
                    return .chat(payloadObj)
                }
            }
            return nil
        case "chat.sessionMessage":
            if let payload = frame.payload {
                let decoded = try? GatewayPayloadDecoding.decode(payload, as: OpenClawSessionMessageEventPayload.self)
                if let payloadObj = decoded {
                    return .sessionMessage(payloadObj)
                }
            }
            return nil
        default:
            if let payload = frame.payload {
                let decoded = try? GatewayPayloadDecoding.decode(payload, as: OpenClawAgentEventPayload.self)
                if let payloadObj = decoded {
                    // AppLogger calls (not direct `print`) per
                    // CLAUDE.md: "Direct use of `os_log` /
                    // `Logger(subsystem:)` is not permitted in app
                    // code — use `AppLogger.log(...)` instead."
                    // Debug-level so the verbose agent-event
                    // payload logging stays off in production
                    // unless the `logsNativeChat` Settings
                    // toggle is on.
                    AppLogger.log("agent event: stream=\(payloadObj.stream), runId=\(payloadObj.runId ?? "nil")", category: .network)
                    AppLogger.log("agent data: \(String(describing: payloadObj.data))", category: .network, level: .debug)
                    AppLogger.log("agent ts: \(String(describing: payloadObj.ts))", category: .network, level: .debug)
                    return .agent(payloadObj)
                }
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
