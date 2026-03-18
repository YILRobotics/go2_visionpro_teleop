import Foundation

enum TeleopSocketError: Error, LocalizedError {
    case notConnected
    case invalidMessageEncoding

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "WebSocket is not connected."
        case .invalidMessageEncoding:
            return "Failed to encode websocket payload."
        }
    }
}

actor TeleopSocketClient {
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    func connect(to url: URL) async throws {
        disconnect()
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        self.task = task
        self.startReceiveLoop(task: task)
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func send(_ packet: TeleopOutboundPacket) async throws {
        guard let task else {
            throw TeleopSocketError.notConnected
        }
        let data = try JSONEncoder().encode(packet)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TeleopSocketError.invalidMessageEncoding
        }
        try await task.send(.string(text))
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveLoopTask = Task.detached {
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string:
                        continue
                    case .data:
                        continue
                    @unknown default:
                        continue
                    }
                } catch {
                    break
                }
            }
        }
    }
}
