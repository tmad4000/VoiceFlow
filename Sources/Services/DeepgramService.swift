import Foundation

/// WebSocket client for Deepgram real-time streaming transcription
/// Uses Apple's native URLSessionWebSocketTask instead of Starscream
class DeepgramService: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let endpoint = "wss://api.deepgram.com/v1/listen"

    @Published var isConnected = false
    @Published var latestTurn: TranscriptTurn?
    @Published var errorMessage: String?

    private var transcribeMode = true
    private var formatTurns = true
    private var vocabularyPrompt: String?
    private var utteranceConfig: UtteranceConfig = .default

    // Track turn order locally since Deepgram doesn't provide it directly in the same way
    private var turnOrder = 0

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
        guard webSocketTask == nil else { return }

        var urlComponents = URLComponents(string: endpoint)!

        // Deepgram query parameters
        // See: https://developers.deepgram.com/docs/streaming-parameters
        // Note: utterance_end_ms must be >= 1000ms
        let effectiveUtteranceEnd = max(1000, utteranceConfig.silenceThresholdMs)
        let effectiveEndpointing = max(500, utteranceConfig.silenceThresholdMs)

        var queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "smart_format", value: String(formatTurns)),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: String(effectiveUtteranceEnd)),
            URLQueryItem(name: "endpointing", value: String(effectiveEndpointing))
        ]

        // Keywords disabled - needs investigation
        // Deepgram returns 400 Bad Request with keywords
        // if let prompt = vocabularyPrompt, !prompt.isEmpty { ... }

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            errorMessage = "Invalid WebSocket URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // Debug logging
        NSLog("[Deepgram] Connecting with native URLSession to: %@", url.absoluteString.prefix(100).description)
        NSLog("[Deepgram] API Key (first 8 chars): %@...", String(apiKey.prefix(8)))

        // Create URLSession with delegate
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessage()
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleMessage(json)
                    }
                case .data(let data):
                    NSLog("[Deepgram] Received binary data: %d bytes", data.count)
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                NSLog("[Deepgram] Receive error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                }
            }
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                // Ignore "Operation canceled" errors - they're expected during disconnect
                let desc = error.localizedDescription
                if desc.contains("canceled") || desc.contains("cancelled") {
                    return
                }
                // Only log if we're still supposed to be connected
                if self?.isConnected == true {
                    NSLog("[Deepgram] Send error: %@", desc)
                }
            }
        }
    }

    /// Force end of current utterance immediately
    func forceEndUtterance() {
        // Deepgram streaming is continuous. Force end is handled by client logic.
        print("DeepgramService: ForceEndUtterance requested (handled by client logic)")
    }

    private func handleMessage(_ message: [String: Any]) {
        // Check for metadata/connected message
        if let type = message["type"] as? String {
            if type == "Metadata" {
                NSLog("[Deepgram] Connected! Metadata received")
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = true
                    self?.errorMessage = nil
                }
                return
            }
            if type == "UtteranceEnd" {
                print("Deepgram UtteranceEnd received")
                return
            }
        }

        // Handle "Results"
        guard let isFinal = message["is_final"] as? Bool else { return }

        guard let channel = message["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first else {
            return
        }

        let transcript = firstAlt["transcript"] as? String ?? ""

        var words: [TranscriptWord] = []
        var turnSpeaker: Int? = nil
        
        if let wordDicts = firstAlt["words"] as? [[String: Any]] {
            words = wordDicts.compactMap {
                let text = ($0["word"] as? String) ?? ($0["punctuated_word"] as? String)
                guard let text else { return nil }
                let startTime = ($0["start"] as? Double) ?? ($0["start"] as? NSNumber)?.doubleValue
                let endTime = ($0["end"] as? Double) ?? ($0["end"] as? NSNumber)?.doubleValue
                let speaker = $0["speaker"] as? Int
                if turnSpeaker == nil && speaker != nil {
                    turnSpeaker = speaker
                }
                return TranscriptWord(text: text, isFinal: isFinal, startTime: startTime, endTime: endTime, speaker: speaker)
            }
        }

        // Only emit if we have something
        if transcript.isEmpty && !isFinal { return }

        let turn = TranscriptTurn(
            transcript: transcript,
            words: words,
            endOfTurn: isFinal,
            isFormatted: formatTurns && isFinal,
            turnOrder: isFinal ? turnOrder : nil,
            utterance: transcript,
            speaker: turnSpeaker
        )

        if isFinal {
            turnOrder += 1
        }

        DispatchQueue.main.async { [weak self] in
            self?.latestTurn = turn
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("[Deepgram] WebSocket opened with protocol: %@", `protocol` ?? "none")
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.errorMessage = nil
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        NSLog("[Deepgram] WebSocket closed: code=%d, reason=%@", closeCode.rawValue, reasonStr)
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            if self?.errorMessage == nil {
                self?.errorMessage = "Disconnected: \(reasonStr)"
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            NSLog("[Deepgram] Session error: %@", error.localizedDescription)
            if let nsError = error as NSError? {
                NSLog("[Deepgram]   Domain: %@, Code: %d", nsError.domain, nsError.code)
                NSLog("[Deepgram]   UserInfo: %@", nsError.userInfo.description)
            }
            // Check HTTP response
            if let httpResponse = task.response as? HTTPURLResponse {
                NSLog("[Deepgram]   HTTP Status: %d", httpResponse.statusCode)
                NSLog("[Deepgram]   Headers: %@", httpResponse.allHeaderFields.description)
            }
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.localizedDescription
                self?.isConnected = false
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        NSLog("[Deepgram] Auth challenge: %@", challenge.protectionSpace.authenticationMethod)
        completionHandler(.performDefaultHandling, nil)
    }

    deinit {
        disconnect()
    }
}
