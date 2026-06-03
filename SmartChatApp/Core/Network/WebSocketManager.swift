import Foundation

final class WebSocketManager: @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    private var _isConnected = false
    private let lock = NSRecursiveLock()

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(url: URL) {
        self.url = url
    }

    func connect() async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        lock.lock()
        _isConnected = true
        lock.unlock()
    }

    func send(_ frame: String) async throws {
        guard isConnected, let task = webSocketTask else {
            throw WebSocketError.notConnected
        }
        try await task.send(.string(frame))
    }

    func receive() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while self.isConnected {
                        guard let task = self.webSocketTask else { break }
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            continuation.yield(text)
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                continuation.yield(text)
                            }
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func disconnect() {
        lock.lock()
        _isConnected = false
        lock.unlock()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }
}

enum WebSocketError: Error {
    case notConnected
    case encodingFailed
}