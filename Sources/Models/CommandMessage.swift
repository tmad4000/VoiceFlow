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

/// A Claude Code session with metadata and chat history
struct ClaudeSession: Codable, Identifiable {
    let id: String                    // Session ID from Claude
    var name: String                  // Auto-generated from first message
    let createdAt: Date
    var lastUsedAt: Date
    var chatHistory: [CommandMessage] // Local message history

    /// Create a new session
    static func create(id: String, firstMessage: String) -> ClaudeSession {
        let name = Self.generateName(from: firstMessage)
        return ClaudeSession(
            id: id,
            name: name,
            createdAt: Date(),
            lastUsedAt: Date(),
            chatHistory: []
        )
    }

    /// Generate a display name from the first message
    static func generateName(from message: String) -> String {
        let cleaned = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= 35 {
            return cleaned
        }
        return String(cleaned.prefix(32)) + "..."
    }

    /// Relative time string (e.g., "2h ago", "yesterday")
    var relativeTime: String {
        let interval = Date().timeIntervalSince(lastUsedAt)
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if hours < 24 { return "\(hours)h ago" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: lastUsedAt)
    }
}
