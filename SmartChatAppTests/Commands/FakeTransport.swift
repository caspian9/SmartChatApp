import Foundation
import SmartChatApp

/// Test double for `ServerCommandTransport`. Configures per-method
/// canned responses and per-method failure counts. Every failure
/// throws `URLError(.timedOut)` — callers should treat it as
/// "transport unavailable" without inspecting the concrete type.
///
/// `failures[method]` is decremented on every attempt; once it
/// hits zero, the method returns its canned response (or `"{}"`
/// if none was set). `responses[method]` is *not* consumed —
/// the same response is returned on every successful call.
@MainActor
final class FakeTransport: ServerCommandTransport {
    var responses: [String: String] = [:]
    var failures: [String: Int] = [:]

    func send(method: String, paramsJSON: String) async throws -> String {
        if let remaining = failures[method], remaining > 0 {
            failures[method] = remaining - 1
            throw URLError(.timedOut)
        }
        return responses[method] ?? "{}"
    }
}
