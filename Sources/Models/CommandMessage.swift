import Foundation

/// Role of a message in the command conversation
enum CommandMessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// A tool use event from Claude Code
struct CommandToolUse: Identifiable, Codable {
    var id = UUID()
    var toolName: String
    var input: String?
    var output: String?
    var isExpanded: Bool = false
    var startTime: Date = Date()
    var endTime: Date?

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var displayName: String {
        // Convert tool names like "mcp_gmail_search" to "Gmail Search"
        toolName
            .replacingOccurrences(of: "mcp_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// A message in the command conversation
struct CommandMessage: Identifiable, Codable {
    var id = UUID()
    var role: CommandMessageRole
    var content: String
    var timestamp: Date = Date()
    var toolUses: [CommandToolUse] = []
    var isStreaming: Bool = false
    var isComplete: Bool = false

    /// Create a user message
    static func user(_ content: String) -> CommandMessage {
        CommandMessage(role: .user, content: content, isComplete: true)
    }

    /// Create an assistant message (starts streaming)
    static func assistant(_ content: String = "", streaming: Bool = true) -> CommandMessage {
        CommandMessage(role: .assistant, content: content, isStreaming: streaming)
    }

    /// Create a system message
    static func system(_ content: String) -> CommandMessage {
        CommandMessage(role: .system, content: content, isComplete: true)
    }
}

/// State for the command panel
struct CommandPanelState {
    var messages: [CommandMessage] = []
    var pendingInput: String = ""
    var messageQueue: [String] = []
    var isProcessing: Bool = false
    var isConnected: Bool = false
    var workingDirectory: String = "~/ai-os"
    var lastError: String?

    /// The response currently being built (for inline commands)
    var inlineResponse: CommandMessage?

    /// Whether to show the inline response overlay
    var showInlineResponse: Bool = false
}
