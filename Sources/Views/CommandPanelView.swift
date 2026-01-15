import SwiftUI
import AppKit

/// Chat interface for Claude Code commands
struct CommandPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var scrollProxy: ScrollViewProxy?
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()
                .background(Color.white.opacity(0.1))

            // Messages
            messageList

            Divider()
                .background(Color.white.opacity(0.1))

            // Input
            inputBar
        }
        .background(
            CommandVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CommandPanelShouldFocusInput"))) { _ in
            isInputFocused = true
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Working directory indicator
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(appState.commandWorkingDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Connection status
            HStack(spacing: 4) {
                Circle()
                    .fill(appState.isClaudeConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(appState.isClaudeConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Close button
            Button(action: closePanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(appState.commandMessages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    // Processing indicator
                    if appState.isClaudeProcessing {
                        HStack {
                            TypingIndicatorView()
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .id("typing-indicator")
                    }
                }
                .padding(.vertical, 12)
            }
            .onAppear {
                scrollProxy = proxy
            }
            .onChange(of: appState.commandMessages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: appState.isClaudeProcessing) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if appState.isClaudeProcessing {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            } else if let lastMessage = appState.commandMessages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask Claude...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }
                .disabled(!appState.isClaudeConnected)

            // Send button
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        appState.isClaudeConnected &&
        !appState.isClaudeProcessing &&
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, appState.isClaudeConnected else { return }

        // Add user message
        appState.commandMessages.append(CommandMessage.user(text))
        inputText = ""

        // Send to Claude
        appState.claudeCodeService?.send(text)

        // Create placeholder assistant message
        appState.commandMessages.append(CommandMessage.assistant())
    }

    private func closePanel() {
        appState.isCommandPanelVisible = false
        NotificationCenter.default.post(
            name: NSNotification.Name("CommandPanelDidClose"),
            object: nil
        )
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: CommandMessage
    @State private var expandedToolIds: Set<UUID> = []

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // Main content
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundColor(message.role == .user ? .white : .primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                }

                // Tool uses (collapsible)
                ForEach(message.toolUses) { toolUse in
                    ToolUseView(
                        toolUse: toolUse,
                        isExpanded: expandedToolIds.contains(toolUse.id),
                        onToggle: {
                            if expandedToolIds.contains(toolUse.id) {
                                expandedToolIds.remove(toolUse.id)
                            } else {
                                expandedToolIds.insert(toolUse.id)
                            }
                        }
                    )
                }

                // Streaming indicator
                if message.isStreaming && message.content.isEmpty {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Thinking...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if message.role != .user {
                Spacer(minLength: 60)
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tool Use View

struct ToolUseView: View {
    let toolUse: CommandToolUse
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)

                    Image(systemName: toolIcon)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)

                    Text(toolUse.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)

                    if let duration = toolUse.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let input = toolUse.input, !input.isEmpty {
                        Text("Input:")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(input)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }

                    if let output = toolUse.output, !output.isEmpty {
                        Text("Output:")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(output.prefix(500) + (output.count > 500 ? "..." : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private var toolIcon: String {
        switch toolUse.toolName.lowercased() {
        case let name where name.contains("read"):
            return "doc.text"
        case let name where name.contains("write"):
            return "pencil"
        case let name where name.contains("bash"):
            return "terminal"
        case let name where name.contains("edit"):
            return "pencil.line"
        case let name where name.contains("search"), let name where name.contains("grep"):
            return "magnifyingglass"
        case let name where name.contains("glob"):
            return "folder"
        default:
            return "wrench"
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(dotCount % 3 == index ? 1.0 : 0.3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        )
        .onReceive(timer) { _ in
            dotCount += 1
        }
    }
}

// MARK: - Visual Effect View (Local copy to avoid conflicts)

struct CommandVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
