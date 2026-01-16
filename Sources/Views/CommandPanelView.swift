import SwiftUI
import AppKit

// MARK: - Multiline Input Field

/// A multiline text input that sends on Enter and adds newlines on Shift+Enter
struct MultilineInputField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13)
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.delegate = context.coordinator
        textView.font = font
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView

        // Only update text if it differs (prevents cursor jump)
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineInputField

        init(_ parent: MultilineInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Check for Shift modifier
                if NSEvent.modifierFlags.contains(.shift) {
                    // Shift+Enter: insert newline
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                } else {
                    // Enter: submit
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}

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

            // Debug panel (collapsible)
            if appState.showClaudeDebugPanel {
                debugPanel
                Divider()
                    .background(Color.white.opacity(0.1))
            }

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
        HStack(spacing: 8) {
            // Working directory indicator
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(appState.commandWorkingDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Model picker
            Picker("", selection: $appState.claudeModel) {
                ForEach(ClaudeModel.allCases) { model in
                    Text(model.shortName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 80)
            .onChange(of: appState.claudeModel) {
                restartServiceWithNewModel()
            }

            // Session picker dropdown
            Menu {
                // List existing sessions
                ForEach(appState.claudeSessions.prefix(10)) { session in
                    Button(action: { appState.switchToSession(session) }) {
                        HStack {
                            if session.id == appState.currentSessionId {
                                Image(systemName: "checkmark")
                            }
                            Text(session.name)
                            Spacer()
                            Text(session.relativeTime)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if !appState.claudeSessions.isEmpty {
                    Divider()
                }

                Button(action: { appState.startNewClaudeSession() }) {
                    Label("New Session", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                    Text(appState.currentSession?.name ?? "New Session")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 150)
            .help("Switch sessions")

            // Debug toggle
            Button(action: { appState.showClaudeDebugPanel.toggle() }) {
                Image(systemName: appState.showClaudeDebugPanel ? "ladybug.fill" : "ladybug")
                    .font(.system(size: 11))
                    .foregroundColor(appState.showClaudeDebugPanel ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle debug panel")

            // Status indicator (Ready/Processing/Error)
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            .help(statusText)

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

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Debug Log")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    appState.claudeDebugLog.removeAll()
                }
                .font(.system(size: 9))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.claudeDebugLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(height: 100)
            .background(Color.black.opacity(0.2))
            .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func restartServiceWithNewModel() {
        // Stop existing service and clear it so it restarts with new model
        appState.claudeCodeService?.stop()
        appState.claudeCodeService = nil
        appState.isClaudeConnected = false
        // It will restart when user sends next message or we can restart now
        appState.claudeDebugLog.append("[Model changed to \(appState.claudeModel.displayName)]")
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
            // Queue indicator
            if !appState.commandMessageQueue.isEmpty {
                Text("\(appState.commandMessageQueue.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .help("\(appState.commandMessageQueue.count) message(s) queued")
            }

            // Multiline input with dynamic height and placeholder
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Ask Claude... (Shift+Enter for newline)")
                        .foregroundColor(.secondary)
                        .font(.system(size: CGFloat(appState.commandPanelFontSize)))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }

                MultilineInputField(
                    text: $inputText,
                    font: .systemFont(ofSize: CGFloat(appState.commandPanelFontSize)),
                    onSubmit: sendMessage
                )
            }
            .frame(height: calculatedInputHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            // Allow typing even during processing (will queue)

            // Stop button (when processing) or Send button
            if appState.isClaudeProcessing {
                Button(action: stopProcessing) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop current request")
            }

            // Send button (always visible, queues if processing)
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(appState.isClaudeProcessing ? "Queue message" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Dynamic height based on content (1-5 lines)
    private var calculatedInputHeight: CGFloat {
        let lineHeight: CGFloat = 18
        let padding: CGFloat = 10
        let minLines: CGFloat = 1
        let maxLines: CGFloat = 5

        let lineCount = CGFloat(max(1, inputText.components(separatedBy: "\n").count))
        let clampedLines = min(max(lineCount, minLines), maxLines)
        return (clampedLines * lineHeight) + padding
    }

    private var statusColor: Color {
        if appState.commandError != nil {
            return .red
        } else if appState.isClaudeProcessing {
            return .blue
        } else {
            return .green  // Ready
        }
    }

    private var statusText: String {
        if let error = appState.commandError {
            return "Error: \(error)"
        } else if appState.isClaudeProcessing {
            return "Processing..."
        } else {
            return "Ready"
        }
    }

    // MARK: - Actions

    private func stopProcessing() {
        appState.claudeCodeService?.interrupt()
        // Mark the last assistant message as interrupted
        if let lastIndex = appState.commandMessages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            appState.commandMessages[lastIndex].isStreaming = false
            appState.commandMessages[lastIndex].content += " [Interrupted]"
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        inputText = ""  // Clear input immediately for good UX

        // Use centralized command handling which supports queuing
        appState.executeInlineCommand(text)
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
    @EnvironmentObject var appState: AppState
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
                        .font(.system(size: CGFloat(appState.commandPanelFontSize)))
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
