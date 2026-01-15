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
    var onEvent: ((ClaudeEvent) -> Void)?

    // MARK: - Initialization

    init(workingDirectory: String = "~/ai-os") {
        self.workingDirectory = (workingDirectory as NSString).expandingTildeInPath
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
        guard process == nil else {
            NSLog("[ClaudeCode] Process already running")
            return
        }

        NSLog("[ClaudeCode] Starting claude process in \(workingDirectory)")

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Find claude executable
        let claudePath = findClaudeExecutable()
        guard FileManager.default.fileExists(atPath: claudePath) else {
            let error = "Claude executable not found at \(claudePath)"
            NSLog("[ClaudeCode] \(error)")
            lastError = error
            onEvent?(.error(error))
            return
        }

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = [
            "--dangerously-skip-permissions",
            "--output-format", "stream-json"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Handle stdout (streaming JSON)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.handleStdout(text)
                }
            }
        }

        // Handle stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.handleStderr(text)
                }
            }
        }

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
            NSLog("[ClaudeCode] Process started successfully")
        } catch {
            NSLog("[ClaudeCode] Failed to start process: \(error)")
            lastError = error.localizedDescription
            onEvent?(.error(error.localizedDescription))
        }
    }

    /// Stop the Claude Code process
    func stop() {
        guard let process = process, process.isRunning else {
            self.process = nil
            return
        }

        NSLog("[ClaudeCode] Stopping claude process")

        // Close stdin to signal EOF
        stdinPipe?.fileHandleForWriting.closeFile()

        // Give it a moment to exit gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak process] in
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    /// Send a message to Claude
    func send(_ message: String) {
        guard let stdinPipe = stdinPipe, process?.isRunning == true else {
            NSLog("[ClaudeCode] Cannot send - process not running")
            lastError = "Process not running"
            return
        }

        NSLog("[ClaudeCode] Sending message: \(message.prefix(100))...")
        isProcessing = true

        // Write the message followed by newline
        let messageWithNewline = message + "\n"
        if let data = messageWithNewline.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    // MARK: - Output Parsing

    private func handleStdout(_ text: String) {
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
        NSLog("[ClaudeCode] stderr: \(text)")
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
                handleJSONEvent(json)
            }
        } catch {
            // Not valid JSON - might be plain text output
            NSLog("[ClaudeCode] Non-JSON output: \(line.prefix(100))")
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
            isProcessing = false
            onEvent?(.messageComplete)

        case "error":
            let errorMsg = json["error"] as? String ?? "Unknown error"
            lastError = errorMsg
            isProcessing = false
            onEvent?(.error(errorMsg))

        default:
            NSLog("[ClaudeCode] Unknown event type: \(type)")
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
}
