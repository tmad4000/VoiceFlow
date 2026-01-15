import Foundation
import Starscream

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
    @Published var lastPingLatencyMs: Int?

    private var transcribeMode = true
    private var formatTurns = true
    private var vocabularyPrompt: String?
    private var utteranceConfig: UtteranceConfig = .default
    private var pingTimer: Timer?
    private var lastPingSentAt: Date?
    private let pingIntervalSeconds: TimeInterval = 10

    // Session expiration handling
    private var sessionExpiresAt: Date?
    private var expirationTimer: Timer?
    private let reconnectBeforeExpirationSeconds: TimeInterval = 30  // Reconnect 30s before expiration
    private var isReconnecting = false

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func setTranscribeMode(_ enabled: Bool) {
        transcribeMode = enabled
    }

    func setFormatTurns(_ enabled: Bool) {
        formatTurns = enabled
    }

    func setVocabularyPrompt(_ prompt: String?) {
        vocabularyPrompt = prompt
    }

    func setUtteranceConfig(_ config: UtteranceConfig) {
        utteranceConfig = config
    }

    func connect() {
        guard socket == nil else { return }

        var urlComponents = URLComponents(string: endpoint)!
        urlComponents.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "format_turns", value: String(formatTurns)),
            URLQueryItem(name: "end_of_turn_confidence_threshold", value: String(utteranceConfig.confidenceThreshold)),
            URLQueryItem(name: "min_end_of_turn_silence_when_confident", value: String(utteranceConfig.silenceThresholdMs)),
            URLQueryItem(name: "max_turn_silence", value: String(utteranceConfig.maxTurnSilenceMs))
        ]

        if let prompt = vocabularyPrompt, !prompt.isEmpty {
            urlComponents.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: prompt))
        }

        guard let url = urlComponents.url else {
            errorMessage = "Invalid WebSocket URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // Debug logging with NSLog
        NSLog("[AssemblyAI] Connecting to: %@", url.absoluteString)
        NSLog("[AssemblyAI] API Key (first 8 chars): %@...", String(apiKey.prefix(8)))
        NSLog("[AssemblyAI] API Key length: %d", apiKey.count)

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
        stopPingTimer()
        stopExpirationTimer()
        sessionExpiresAt = nil
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
            let sessionId = message["id"] as? String ?? "unknown"
            print("Session started: \(sessionId)")

            // Parse session expiration time and schedule reconnection
            // expires_at can be Int or Double depending on JSON parsing
            var expiresAtUnix: TimeInterval? = nil
            if let unix = message["expires_at"] as? TimeInterval {
                expiresAtUnix = unix
            } else if let unix = message["expires_at"] as? Int {
                expiresAtUnix = TimeInterval(unix)
            } else if let unix = (message["expires_at"] as? NSNumber)?.doubleValue {
                expiresAtUnix = unix
            }

            if let unix = expiresAtUnix {
                let expiresAt = Date(timeIntervalSince1970: unix)
                sessionExpiresAt = expiresAt
                let expiresInSeconds = expiresAt.timeIntervalSinceNow
                NSLog("[AssemblyAI] Session expires at: \(expiresAt) (in \(Int(expiresInSeconds))s)")
                // Schedule on main thread to ensure timer fires
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleExpirationReconnect(expiresAt: expiresAt)
                }
            }

        case "Turn":
            let transcript = message["transcript"] as? String ?? ""
            let endOfTurn = message["end_of_turn"] as? Bool ?? false
            let isFormatted = message["turn_is_formatted"] as? Bool ?? false
            let turnOrder = message["turn_order"] as? Int
            let utterance = message["utterance"] as? String

            var words: [TranscriptWord] = []
            var turnSpeaker: String? = nil
            if let wordDictionaries = message["words"] as? [[String: Any]] {
                words = wordDictionaries.compactMap { word in
                    let text = (word["text"] as? String) ?? (word["word"] as? String)
                    guard let text else { return nil }
                    let isFinal = (word["word_is_final"] as? Bool) ?? (word["is_final"] as? Bool)
                    let startTime = (word["start"] as? Double) ?? (word["start"] as? NSNumber)?.doubleValue
                    let endTime = (word["end"] as? Double) ?? (word["end"] as? NSNumber)?.doubleValue
                    let speakerRaw = word["speaker"] as? String
                    let speaker = speakerRaw.flatMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) ?? Int($0) }
                    
                    if turnSpeaker == nil {
                        turnSpeaker = speakerRaw
                    }
                    
                    return TranscriptWord(text: text, isFinal: isFinal, startTime: startTime, endTime: endTime, speaker: speaker)
                }
            }

            let turn = TranscriptTurn(
                transcript: transcript,
                words: words,
                endOfTurn: endOfTurn,
                isFormatted: isFormatted,
                turnOrder: turnOrder,
                utterance: utterance,
                speaker: turnSpeaker.flatMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) ?? Int($0) }
            )

            DispatchQueue.main.async { [weak self] in
                self?.latestTurn = turn
            }

        case "Termination":
            print("Session terminated")
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }

        case "PartialTranscript", "FinalTranscript":
            let transcript = message["text"] as? String ?? ""
            let isFinal = type == "FinalTranscript"
            
            var words: [TranscriptWord] = []
            var turnSpeaker: Int? = nil
            if let wordDictionaries = message["words"] as? [[String: Any]] {
                words = wordDictionaries.compactMap { word in
                    let text = word["text"] as? String
                    guard let text else { return nil }
                    let startTime = (word["start"] as? Double) ?? (word["start"] as? NSNumber)?.doubleValue
                    let endTime = (word["end"] as? Double) ?? (word["end"] as? NSNumber)?.doubleValue
                    let speakerRaw = word["speaker"] as? String
                    let speaker = speakerRaw.flatMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) ?? Int($0) }
                    if turnSpeaker == nil { turnSpeaker = speaker }
                    return TranscriptWord(text: text, isFinal: isFinal, startTime: startTime, endTime: endTime, speaker: speaker)
                }
            }

            let turn = TranscriptTurn(
                transcript: transcript,
                words: words,
                endOfTurn: isFinal,
                isFormatted: false,
                turnOrder: nil,
                utterance: transcript,
                speaker: turnSpeaker
            )

            DispatchQueue.main.async { [weak self] in
                self?.latestTurn = turn
            }

        case "Error":
            if let error = message["error"] as? String {
                NSLog("[AssemblyAI] Error received: %@", error)
                // Check if this is a session expiration error - attempt automatic reconnection
                let lowerError = error.lowercased()
                if lowerError.contains("session expired") || lowerError.contains("maximum session duration") {
                    NSLog("[AssemblyAI] Session expired - attempting automatic reconnection")
                    handleSessionExpiration()
                    return  // Don't show error to user - we're handling it
                }
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
            startPingTimer()

        case .disconnected(let reason, let code):
            print("WebSocket disconnected: \(reason) (code: \(code))")
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
                self?.errorMessage = "Disconnected: \(reason)"
            }
            stopPingTimer()
            stopExpirationTimer()

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
            stopPingTimer()
            stopExpirationTimer()

        case .cancelled:
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }
            print("WebSocket cancelled")
            stopPingTimer()
            stopExpirationTimer()

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
            stopPingTimer()
            stopExpirationTimer()

        case .ping:
            break

        case .pong:
            if let sentAt = lastPingSentAt {
                let latencyMs = Int(Date().timeIntervalSince(sentAt) * 1000)
                DispatchQueue.main.async { [weak self] in
                    self?.lastPingLatencyMs = latencyMs
                }
            }
        }
    }
}

private extension AssemblyAIService {
    func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingIntervalSeconds, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        lastPingSentAt = nil
        lastPingLatencyMs = nil
    }

    func sendPing() {
        guard isConnected, let socket = socket else { return }
        lastPingSentAt = Date()
        socket.write(ping: Data())
    }

    // MARK: - Session Expiration Handling

    func scheduleExpirationReconnect(expiresAt: Date) {
        stopExpirationTimer()

        // Calculate when to reconnect (30 seconds before expiration)
        let reconnectTime = expiresAt.addingTimeInterval(-reconnectBeforeExpirationSeconds)
        let timeUntilReconnect = reconnectTime.timeIntervalSinceNow

        if timeUntilReconnect <= 0 {
            // Already past reconnection time - reconnect immediately
            NSLog("[AssemblyAI] Session about to expire - reconnecting immediately")
            handleSessionExpiration()
            return
        }

        NSLog("[AssemblyAI] Scheduling proactive reconnection in \(Int(timeUntilReconnect))s (30s before expiration)")

        expirationTimer = Timer.scheduledTimer(withTimeInterval: timeUntilReconnect, repeats: false) { [weak self] _ in
            NSLog("[AssemblyAI] Proactive session reconnection triggered")
            self?.handleSessionExpiration()
        }
    }

    func stopExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    func handleSessionExpiration() {
        // Must run on main thread for UI updates and timer management
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleSessionExpiration()
            }
            return
        }

        guard !isReconnecting else {
            NSLog("[AssemblyAI] Already reconnecting - skipping duplicate request")
            return
        }

        NSLog("[AssemblyAI] Handling session expiration - will reconnect")
        isReconnecting = true
        stopExpirationTimer()

        // Mark as disconnected so audio isn't sent to dead socket
        isConnected = false

        // Disconnect existing socket
        if let socket = socket {
            socket.disconnect()
            self.socket = nil
        }
        stopPingTimer()
        sessionExpiresAt = nil

        // Reconnect after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            NSLog("[AssemblyAI] Reconnecting after session expiration...")
            self.isReconnecting = false
            self.connect()
        }
    }
}
