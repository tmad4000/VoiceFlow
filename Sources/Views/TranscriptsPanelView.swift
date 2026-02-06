import SwiftUI
import AppKit

/// Panel for viewing dictation transcripts/history
struct TranscriptsPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""

    var filteredHistory: [String] {
        let history = appState.dictationHistory
        if searchText.isEmpty {
            return history
        }
        return history.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
                .padding(.top, 28) // Padding for window buttons (traffic lights)

            Divider()

            // Search bar
            searchBar

            Divider()

            // Content
            if appState.dictationHistory.isEmpty {
                emptyState
            } else if filteredHistory.isEmpty {
                noResultsState
            } else {
                transcriptsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            TranscriptsVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Transcripts")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Text("\(filteredHistory.count) entries")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button(action: clearHistory) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear history")

            Button(action: closePanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("Search transcripts...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcripts List

    private var transcriptsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(filteredHistory.enumerated()), id: \.offset) { index, entry in
                    TranscriptRowView(entry: entry, index: index)
                        .contextMenu {
                            Button("Copy to Clipboard") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry, forType: .string)
                            }
                            Button("Retype This") {
                                appState.retypeText(entry)
                            }
                        }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Transcripts Yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("Start dictating and your transcripts will appear here")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - No Results State

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Matches")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("No transcripts match '\(searchText)'")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func clearHistory() {
        appState.clearDictationHistory()
    }

    private func closePanel() {
        appState.isTranscriptsPanelVisible = false
    }
}

// MARK: - Transcript Row View

struct TranscriptRowView: View {
    let entry: String
    let index: Int

    var isCommand: Bool {
        entry.hasPrefix("[Command]")
    }

    var displayText: String {
        if isCommand {
            return String(entry.dropFirst("[Command]".count)).trimmingCharacters(in: .whitespaces)
        }
        return entry
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Type indicator
            Image(systemName: isCommand ? "command" : "waveform")
                .font(.system(size: 10))
                .foregroundColor(isCommand ? .orange : .secondary)
                .frame(width: 16)

            // Content
            Text(displayText)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCommand ? Color.orange.opacity(0.1) : Color(nsColor: .textBackgroundColor).opacity(0.3))
        )
    }
}

// MARK: - Visual Effect View

struct TranscriptsVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
