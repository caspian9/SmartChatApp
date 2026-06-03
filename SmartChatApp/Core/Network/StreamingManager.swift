import Foundation

actor StreamingManager {
    private var buffer: String = ""
    private var currentToolCall: ToolCall?

    func processEvent(_ event: GatewayEvent) -> StreamResult {
        switch event {
        case .event(let frame):
            return processEventFrame(frame)
        case .response(let frame):
            return processResponseFrame(frame)
        }
    }

    private func processEventFrame(_ frame: EventFrame) -> StreamResult {
        switch frame.event {
        case "response.created":
            return .responseStarted
        case "response.in_progress":
            return .responseInProgress
        case "output_item.added":
            if let item = extractOutputItem(from: frame.payload?.value) {
                switch item.type {
                case "message":
                    return .messageStarted(item.id)
                case "function_call":
                    return .toolCallStarted(ToolCall(id: item.id, name: item.name ?? "", arguments: item.arguments ?? ""))
                default:
                    return .unknown
                }
            }
            return .unknown
        case "output_text.delta":
            if let delta = extractTextDelta(from: frame.payload?.value) {
                return .textDelta(delta)
            }
            return .unknown
        case "output_text.done":
            return .textDone
        case "response.completed":
            return .responseCompleted
        default:
            return .unknown
        }
    }

    private func processResponseFrame(_ frame: ResponseFrame) -> StreamResult {
        guard frame.ok, let payload = frame.payload?.value as? [String: Any] else {
            return .error(frame.error?.message ?? "Unknown error")
        }

        if let sessionKey = payload["key"] as? String {
            return .sessionCreated(sessionKey)
        }

        return .unknown
    }

    private func extractOutputItem(from value: Any?) -> OutputItem? {
        guard let dict = value as? [String: Any] else { return nil }
        return OutputItem(
            type: dict["type"] as? String ?? "",
            id: dict["id"] as? String ?? "",
            name: dict["name"] as? String,
            arguments: dict["arguments"] as? String
        )
    }

    private func extractTextDelta(from value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        return dict["delta"] as? String ?? dict["text"] as? String
    }
}

struct OutputItem {
    let type: String
    let id: String
    let name: String?
    let arguments: String?
}

enum StreamResult {
    case responseStarted
    case responseInProgress
    case messageStarted(String)
    case toolCallStarted(ToolCall)
    case textDelta(String)
    case textDone
    case responseCompleted
    case sessionCreated(String)
    case error(String)
    case unknown
}