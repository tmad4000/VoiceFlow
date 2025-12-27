import Foundation
import Starscream

/// WebSocket client for AssemblyAI real-time streaming transcription
class AssemblyAIService: NSObject, ObservableObject {
    private let apiKey: String
    private var socket: WebSocket?
    private let endpoint = "wss://streaming.assemblyai.com/v3/ws"

    @Published var isConnected = false
    @Published var transcript = ""
    @Published var errorMessage: String?

    private var transcribeMode = true
    private var pendingTranscript = ""

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func setTranscribeMode(_ enabled: Bool) {
        transcribeMode = enabled
    }

    func connect() {
        guard socket == nil else { return }

        var urlComponents = URLComponents(string: endpoint)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "format_turns", value: "true")
        ]

        guard let url = urlComponents.url else {
            errorMessage = "Invalid WebSocket URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }

    func disconnect() {
        guard let socket = socket else { return }

        // Send terminate message
        let terminateMessage: [String: Any] = ["type": "Terminate"]
        if let data = try? JSONSerialization.data(withJSONObject: terminateMessage) {
            socket.write(string: String(data: data, encoding: .utf8) ?? "")
        }

        socket.disconnect()
        self.socket = nil
        isConnected = false
    }

    func sendAudio(_ data: Data) {
        guard isConnected, let socket = socket else { return }
        socket.write(data: data)
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "Begin":
            print("Session started: \(message["id"] ?? "unknown")")

        case "Turn":
            if let text = message["transcript"] as? String, !text.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.transcript = text
                }
            }

        case "Termination":
            print("Session terminated")
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }

        case "Error":
            if let error = message["error"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error
                }
            }

        default:
            break
        }
    }

    deinit {
        disconnect()
    }
}

// MARK: - WebSocketDelegate

extension AssemblyAIService: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected(_):
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
                self?.errorMessage = nil
            }
            print("WebSocket connected")

        case .disconnected(let reason, let code):
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }
            print("WebSocket disconnected: \(reason) (code: \(code))")

        case .text(let text):
            if let data = text.data(using: .utf8),
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                handleMessage(message)
            }

        case .binary(let data):
            // Unexpected binary data from server
            print("Received binary data: \(data.count) bytes")

        case .error(let error):
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error?.localizedDescription ?? "WebSocket error"
                self?.isConnected = false
            }
            print("WebSocket error: \(String(describing: error))")

        case .cancelled:
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }
            print("WebSocket cancelled")

        case .viabilityChanged(let viable):
            print("WebSocket viability: \(viable)")

        case .reconnectSuggested(let suggested):
            if suggested {
                print("WebSocket reconnect suggested")
            }

        case .peerClosed:
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }
            print("WebSocket peer closed")

        case .ping, .pong:
            break
        }
    }
}
