import Foundation
import Combine

/// Service to communicate with Claude Code CLI
/// Spawns and manages the claude process with streaming JSON output
@MainActor
class ClaudeCodeService: ObservableObject {

    // MARK: - Types

    enum ClaudeEvent {
        case connected
        case disconnected(Error?)
        case textChunk(String)
        case textComplete(String)
        case toolUseStart(id: String, name: String, input: String?)
        case toolUseEnd(id: String, output: String?)
        case messageComplete
        case sessionId(String)  // Session ID from Claude Code for --resume
        case error(String)
    }

    // MARK: - Properties

    @Published var isConnected: Bool = false
    @Published var isProcessing: Bool = false
    @Published var lastError: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer: String = ""

    let workingDirectory: String
    var model: String?  // e.g., "opus", "haiku", or nil for default (sonnet)
    var sessionId: String?  // Current session ID for --resume
    var onEvent: ((ClaudeEvent) -> Void)?
    var onDebugLog: ((String) -> Void)?  // For debug panel

    // MARK: - Initialization

    init(workingDirectory: String = "~/code/ai-os-apple-data/workspace", model: String? = nil) {
        self.workingDirectory = (workingDirectory as NSString).expandingTildeInPath
        self.model = model
    }

    nonisolated func cleanup() {
        // Called from deinit - terminate process synchronously
        Task { @MainActor in
            self.stop()
        }
    }

    // MARK: - Process Lifecycle

    /// Start the Claude Code process
    func start() {
        debugLog("start() called")

        guard process == nil else {
            debugLog("Process already running, skipping")
            return
        }

        // Verify working directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue else {
            debugLog("ERROR: Working directory does not exist: \(workingDirectory)")
            lastError = "Working directory does not exist: \(workingDirectory)"
            onEvent?(.error(lastError!))
            return
        }

        debugLog("Starting in: \(workingDirectory)")

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Find claude executable
        let claudePath = findClaudeExecutable()
        debugLog("Found claude at: \(claudePath)")
        guard FileManager.default.fileExists(atPath: claudePath) else {
            let error = "Claude executable not found at \(claudePath)"
            NSLog("[ClaudeCode] \(error)")
            lastError = error
            onEvent?(.error(error))
            return
        }

        process.executableURL = URL(fileURLWithPath: claudePath)
        var args = [
            "--dangerously-skip-permissions",
            "--print",  // Required for --output-format to work
            "--input-format", "stream-json",  // Accept JSON input
            "--output-format", "stream-json",
            "--verbose"
        ]
        // Add --resume if we have a session ID (enables multi-turn with full context)
        if let sessionId = sessionId {
            args.append(contentsOf: ["--resume", sessionId])
            debugLog("Resuming session: \(sessionId)")
        }
        // Add model flag if specified
        if let model = model {
            args.append(contentsOf: ["--model", model])
            debugLog("Using model: \(model)")
        }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Inherit environment and add common paths for node, etc.
        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()
        let additionalPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDir)/.nvm/versions/node/*/bin",
            "\(homeDir)/.local/bin"
        ]
        if let existingPath = env["PATH"] {
            env["PATH"] = additionalPaths.joined(separator: ":") + ":" + existingPath
        }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Use simple background thread reading (most reliable approach)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        NSLog("[ClaudeCode] Starting stdout reader thread")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NSLog("[ClaudeCode] stdout reader thread started")
            while true {
                let data = stdoutHandle.availableData
                if data.isEmpty {
                    NSLog("[ClaudeCode] stdout: EOF received")
                    break
                }
                NSLog("[ClaudeCode] stdout: received \(data.count) bytes")
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("[ClaudeCode] stdout text: \(text.prefix(300))")
                    Task { @MainActor [weak self] in
                        self?.handleStdout(text)
                    }
                }
            }
            NSLog("[ClaudeCode] stdout reader thread ended")
        }

        NSLog("[ClaudeCode] Starting stderr reader thread")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NSLog("[ClaudeCode] stderr reader thread started")
            while true {
                let data = stderrHandle.availableData
                if data.isEmpty {
                    NSLog("[ClaudeCode] stderr: EOF received")
                    break
                }
                NSLog("[ClaudeCode] stderr: received \(data.count) bytes")
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("[ClaudeCode] stderr text: \(text.prefix(300))")
                    Task { @MainActor [weak self] in
                        self?.handleStderr(text)
                    }
                }
            }
            NSLog("[ClaudeCode] stderr reader thread ended")
        }
        NSLog("[ClaudeCode] Background readers started")

        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                let code = proc.terminationStatus
                NSLog("[ClaudeCode] Process terminated with code \(code)")
                self?.isConnected = false
                self?.isProcessing = false
                self?.process = nil
                self?.onEvent?(.disconnected(code != 0 ? NSError(domain: "ClaudeCode", code: Int(code)) : nil))
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.isConnected = true
            self.lastError = nil
            onEvent?(.connected)
            debugLog("Process started: PID \(process.processIdentifier)")
        } catch {
            NSLog("[ClaudeCode] Failed to start process: \(error)")
            lastError = error.localizedDescription
            onEvent?(.error(error.localizedDescription))
        }
    }

    /// Stop the Claude Code process
    func stop() {
        guard let currentProcess = process else {
            return
        }

        NSLog("[ClaudeCode] Stopping claude process")

        // Clear references first to prevent race conditions
        let oldStdinPipe = stdinPipe
        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        // Close stdin to signal EOF
        oldStdinPipe?.fileHandleForWriting.closeFile()

        // Terminate if still running
        if currentProcess.isRunning {
            currentProcess.terminate()
        }
    }

    /// Interrupt the current request (send SIGINT)
    func interrupt() {
        guard let process = process, process.isRunning else {
            NSLog("[ClaudeCode] Cannot interrupt - process not running")
            return
        }

        NSLog("[ClaudeCode] Sending SIGINT to interrupt current request")
        process.interrupt()  // Sends SIGINT
        isProcessing = false
    }

    /// Send a message to Claude (spawns a new process for each message in --print mode)
    /// Uses --resume with sessionId for multi-turn conversations with full context
    /// - Parameter message: The user message to send
    func send(_ message: String) {
        debugLog("SEND: \(message.prefix(100))...")
        isProcessing = true

        // Stop any existing process first
        if process?.isRunning == true {
            stop()
        }

        // Start a fresh process for this message (with --resume if we have sessionId)
        start()

        guard let stdinPipe = stdinPipe, process?.isRunning == true else {
            debugLog("ERROR: Cannot send - process not running")
            lastError = "Process not running"
            isProcessing = false
            return
        }

        // Format message as JSON for stream-json input format
        // No need to inject conversation history - --resume handles that
        let jsonMessage: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonMessage)
            if var jsonString = String(data: jsonData, encoding: .utf8) {
                jsonString += "\n"
                if let data = jsonString.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                    debugLog("SENT JSON: \(jsonString.prefix(100))...")
                    // Close stdin to signal end of input and trigger response
                    stdinPipe.fileHandleForWriting.closeFile()
                    debugLog("Closed stdin to trigger response")
                }
            }
        } catch {
            debugLog("ERROR: Failed to serialize JSON: \(error)")
            lastError = "Failed to serialize message"
            isProcessing = false
        }
    }

    /// Clear the current session (start fresh on next message)
    func clearSession() {
        sessionId = nil
    }

    // MARK: - Output Parsing

    private func handleStdout(_ text: String) {
        debugLog("stdout: \(text.prefix(300))")
        outputBuffer += text

        // Process complete JSON lines
        while let newlineIndex = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer = String(outputBuffer[outputBuffer.index(after: newlineIndex)...])

            if !line.isEmpty {
                parseJSONLine(line)
            }
        }
    }

    private func handleStderr(_ text: String) {
        debugLog("stderr: \(text)")
        // stderr is often just informational, but log errors
        if text.lowercased().contains("error") {
            lastError = text
            onEvent?(.error(text))
        }
    }

    private func parseJSONLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let eventType = json["type"] as? String ?? "unknown"
                debugLog("JSON event: \(eventType)")
                handleJSONEvent(json)
            }
        } catch {
            // Not valid JSON - might be plain text output
            debugLog("Non-JSON: \(line.prefix(100))")
            // If it looks like a prompt or status, emit as text chunk
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                onEvent?(.textChunk(line + "\n"))
            }
        }
    }

    private func handleJSONEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "assistant":
            // Assistant message starting
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let blockType = block["type"] as? String {
                        if blockType == "text", let text = block["text"] as? String {
                            onEvent?(.textChunk(text))
                        }
                    }
                }
            }

        case "content_block_start":
            if let contentBlock = json["content_block"] as? [String: Any],
               let blockType = contentBlock["type"] as? String {
                if blockType == "tool_use" {
                    let id = contentBlock["id"] as? String ?? UUID().uuidString
                    let name = contentBlock["name"] as? String ?? "unknown"
                    onEvent?(.toolUseStart(id: id, name: name, input: nil))
                }
            }

        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any] {
                if let deltaType = delta["type"] as? String {
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        onEvent?(.textChunk(text))
                    } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                        // Tool input being streamed
                        NSLog("[ClaudeCode] Tool input delta: \(partial.prefix(50))")
                    }
                }
            }

        case "content_block_stop":
            // A content block finished
            break

        case "message_stop":
            isProcessing = false
            onEvent?(.messageComplete)

        case "result":
            // Final result with full text
            if let result = json["result"] as? String {
                onEvent?(.textComplete(result))
            }
            // Capture session_id for --resume support
            if let newSessionId = json["session_id"] as? String {
                self.sessionId = newSessionId
                debugLog("Captured session_id: \(newSessionId)")
                onEvent?(.sessionId(newSessionId))
            }
            isProcessing = false
            onEvent?(.messageComplete)

        case "error":
            let errorMsg = json["error"] as? String ?? "Unknown error"
            lastError = errorMsg
            isProcessing = false
            onEvent?(.error(errorMsg))

        case "system":
            // System message/prompt - can be ignored or logged
            if let message = json["message"] as? String {
                NSLog("[ClaudeCode] System: \(message.prefix(100))")
            }

        case "user":
            // Echo of user input - can be ignored
            break

        case "init":
            // Initialization complete
            NSLog("[ClaudeCode] Init event received")

        default:
            NSLog("[ClaudeCode] Unknown event type: \(type) - \(json)")
        }
    }

    // MARK: - Helpers

    private func findClaudeExecutable() -> String {
        // Check common locations
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/bin/claude"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try which command
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["claude"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            NSLog("[ClaudeCode] which failed: \(error)")
        }

        // Default fallback
        return "/usr/local/bin/claude"
    }

    private func debugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"
        NSLog("[ClaudeCode] \(message)")
        onDebugLog?(logEntry)
    }
}
