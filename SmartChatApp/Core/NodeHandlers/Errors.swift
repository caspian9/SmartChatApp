import Foundation
import OpenClawKit

public enum NodeHandlerError: Error, LocalizedError {
    case unavailable(reason: String)
    case permissionRequired(feature: String)
    case backgroundUnavailable(feature: String)
    case unknownCommand(command: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .permissionRequired(let feature):
            return "\(feature) permission required"
        case .backgroundUnavailable(let feature):
            return "\(feature) background unavailable"
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        }
    }

    public var errorCode: String {
        switch self {
        case .unavailable:
            return "unavailable"
        case .permissionRequired:
            return "permission_required"
        case .backgroundUnavailable:
            return "background_unavailable"
        case .unknownCommand:
            return "unknown_command"
        }
    }

    public func toOpenClawError() -> OpenClawNodeError {
        OpenClawNodeError(code: .unavailable, message: errorDescription ?? "")
    }
}

public typealias CommandHandler = (BridgeInvokeRequest) async throws -> BridgeInvokeResponse

public enum CommandResult {
    case success(payload: Encodable)
    case error(NodeHandlerError)
    case notImplemented(command: String)

    public func toResponse(requestId: String) -> BridgeInvokeResponse {
        switch self {
        case .success(let payload):
            let encoder = JSONEncoder()
            let payloadData = try? encoder.encode(payload)
            let payloadJSON = payloadData.flatMap { String(data: $0, encoding: .utf8) }
            return BridgeInvokeResponse(
                type: "response",
                id: requestId,
                ok: true,
                payloadJSON: payloadJSON,
                error: nil
            )
        case .error(let error):
            return BridgeInvokeResponse(
                type: "response",
                id: requestId,
                ok: false,
                payloadJSON: nil,
                error: error.toOpenClawError()
            )
        case .notImplemented(let command):
            return BridgeInvokeResponse(
                type: "response",
                id: requestId,
                ok: false,
                payloadJSON: nil,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "Command not implemented: \(command)"
                )
            )
        }
    }
}