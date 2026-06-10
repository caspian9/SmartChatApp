import Foundation
import SmartChatApp

/// Test double for `ServerCommandTransport`. Configures per-method
/// canned responses and per-method failure counts. Every failure
/// throws `URLError(.timedOut)` — callers should treat it as
/// "transport unavailable" without inspecting the concrete type.
///
/// `failures[method]` is decremented on every attempt; once it
/// hits zero, the method returns its canned response (or empty
/// `Data` if none was set). `responses[method]` is *not* consumed —
/// the same response is returned on every successful call.
@MainActor
final class FakeTransport: ServerCommandTransport {
    struct ServerCommandCall: Equatable {
        let method: String
        let text: String
    }

    var responses: [String: Data] = [:]
    var failures: [String: Int] = [:]
    var calls: [ServerCommandCall] = []

    func send(method: String, paramsJSON: String) async throws -> Data {
        if let remaining = failures[method], remaining > 0 {
            failures[method] = remaining - 1
            throw URLError(.timedOut)
        }
        return responses[method] ?? Data()
    }

    /// Stand-in for the SDK's `sendMessage(...)` we hook into
    /// from `NativeChatViewModel.sendAsMessage(text:)`. Captures
    /// the call so the test can assert on it.
    func recordSendMessageCall(text: String) {
        calls.append(ServerCommandCall(method: "chat.send", text: text))
    }
}
