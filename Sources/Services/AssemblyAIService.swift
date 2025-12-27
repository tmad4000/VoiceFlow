import Foundation
import Starscream

struct TranscriptWord {
    let text: String
    let isFinal: Bool?
    let startTime: Double?
    let endTime: Double?
}

struct TranscriptTurn {
    let transcript: String
    let words: [TranscriptWord]
    let endOfTurn: Bool
    let isFormatted: Bool
    let turnOrder: Int?
    let utterance: String?
}

/// Configuration for utterance detection
struct UtteranceConfig {
    let confidenceThreshold: Double
    let silenceThresholdMs: Int
    let maxTurnSilenceMs: Int

    static let `default` = UtteranceConfig(confidenceThreshold: 0.7, silenceThresholdMs: 160, maxTurnSilenceMs: 1280)
}

/// WebSocket client for AssemblyAI real-time streaming transcription
class AssemblyAIService: NSObject, ObservableObject {
    private let apiKey: String
    private var socket: WebSocket?
    private let endpoint = "wss://streaming.assemblyai.com/v3/ws"

    @Published var isConnected = false
    @Published var latestTurn: TranscriptTurn?
    @Published var errorMessage: String?

    private var transcribeMode = true
    private var utteranceConfig: UtteranceConfig = .default

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func setTranscribeMode(_ enabled: Bool) {
        transcribeMode = enabled
    }

    func setUtteranceConfig(_ config: UtteranceConfig) {
        utteranceConfig = config
    }

    func connect() {
        guard socket == nil else { return }

        var urlComponents = URLComponents(string: endpoint)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "end_of_turn_confidence_threshold", value: String(utteranceConfig.confidenceThreshold)),
            URLQueryItem(name: "min_end_of_turn_silence_when_confident", value: String(utteranceConfig.silenceThresholdMs)),
            URLQueryItem(name: "max_turn_silence", value: String(utteranceConfig.maxTurnSilenceMs))
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

    /// Force end of current utterance immediately
    func forceEndUtterance() {
        guard isConnected, let socket = socket else {
            print("ForceEndUtterance skipped: not connected")
            return
        }
        let message: [String: Any] = ["type": "ForceEndUtterance"]
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: data, encoding: .utf8) {
            socket.write(string: jsonString)
            print("Sent ForceEndUtterance message")
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "Begin":
            print("Session started: \(message["id"] ?? "unknown")")

        case "Turn":
            let transcript = message["transcript"] as? String ?? ""
            let endOfTurn = message["end_of_turn"] as? Bool ?? false
            let isFormatted = message["turn_is_formatted"] as? Bool ?? false
            let turnOrder = message["turn_order"] as? Int
            let utterance = message["utterance"] as? String

            var words: [TranscriptWord] = []
            if let wordDictionaries = message["words"] as? [[String: Any]] {
                words = wordDictionaries.compactMap { word in
                    let text = (word["text"] as? String) ?? (word["word"] as? String)
                    guard let text else { return nil }
                    let isFinal = (word["word_is_final"] as? Bool) ?? (word["is_final"] as? Bool)
                    let startTime = (word["start"] as? Double) ?? (word["start"] as? NSNumber)?.doubleValue
                    let endTime = (word["end"] as? Double) ?? (word["end"] as? NSNumber)?.doubleValue
                    return TranscriptWord(text: text, isFinal: isFinal, startTime: startTime, endTime: endTime)
                }
            }

            let turn = TranscriptTurn(
                transcript: transcript,
                words: words,
                endOfTurn: endOfTurn,
                isFormatted: isFormatted,
                turnOrder: turnOrder,
                utterance: utterance
            )

            DispatchQueue.main.async { [weak self] in
                self?.latestTurn = turn
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
            print("WebSocket disconnected: \(reason) (code: \(code))")
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
                self?.errorMessage = "Disconnected: \(reason)"
            }

        case .text(let text):
            if let data = text.data(using: .utf8),
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let type = message["type"] as? String, type != "Turn" {
                    print("Received message: \(type)")
                }
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
