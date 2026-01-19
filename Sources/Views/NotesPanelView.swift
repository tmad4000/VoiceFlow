import SwiftUI
import AppKit

/// Panel for viewing and managing voice notes
struct NotesPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var notes: [NoteFile] = []
    @State private var selectedNote: NoteFile?
    @State private var viewingNote: NoteFile?  // Note being viewed in popup
    @State private var searchText: String = ""
    @State private var isLoading: Bool = true
    @State private var isCreatingNote: Bool = false
    @State private var newNoteText: String = ""
    @AppStorage("notesFullTextMode") private var fullTextMode: Bool = false
    @AppStorage("noteCollapseStatesData") private var collapseStatesData: Data = Data()

    private let notesDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("VoiceFlow/Notes", isDirectory: true)
    }()

    /// Length threshold for showing collapse option (characters)
    private let collapseThreshold: Int = 200

    var filteredNotes: [NoteFile] {
        if searchText.isEmpty {
            return notes
        }
        return notes.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Collapse State Management

    private var collapseStates: [String: Bool] {
        get {
            (try? JSONDecoder().decode([String: Bool].self, from: collapseStatesData)) ?? [:]
        }
    }

    private func setCollapseStates(_ states: [String: Bool]) {
        collapseStatesData = (try? JSONEncoder().encode(states)) ?? Data()
    }

    private func isNoteCollapsed(_ note: NoteFile) -> Bool {
        collapseStates[note.url.path] ?? false  // default: expanded
    }

    private func toggleNoteCollapsed(_ note: NoteFile) {
        var states = collapseStates
        states[note.url.path] = !isNoteCollapsed(note)
        setCollapseStates(states)
    }

    private func cleanupCollapseState(for note: NoteFile) {
        var states = collapseStates
        states.removeValue(forKey: note.url.path)
        setCollapseStates(states)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Search bar
            searchBar

            Divider()

            // Content
            if isLoading {
                ProgressView("Loading notes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notes.isEmpty {
                emptyState
            } else {
                notesList
            }
        }
        .background(
            NotesVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            loadNotes()
        }
        .sheet(isPresented: $isCreatingNote) {
            newNoteSheet
        }
        .sheet(item: $viewingNote) { note in
            noteViewSheet(note: note)
        }
    }

    // MARK: - New Note Sheet

    private var newNoteSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("New Note")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") {
                    isCreatingNote = false
                    newNoteText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("Save") {
                    saveNewNote()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextEditor(text: $newNoteText)
                .font(.system(size: 13))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .cornerRadius(8)
        }
        .padding()
        .frame(width: 350, height: 250)
    }

    // MARK: - Note View Sheet

    private func noteViewSheet(note: NoteFile) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("View Note")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(note.formattedDate)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("Done") {
                    viewingNote = nil
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                Text(note.content)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
            .cornerRadius(8)

            HStack {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.content, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSWorkspace.shared.selectFile(note.url.path, inFileViewerRootedAtPath: "")
                }) {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .foregroundColor(.secondary)
            .font(.system(size: 12))
        }
        .padding()
        .frame(width: 400, height: 350)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Notes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Text("\(filteredNotes.count) notes")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button(action: { fullTextMode.toggle() }) {
                Image(systemName: fullTextMode ? "text.alignleft" : "list.bullet")
                    .font(.system(size: 11))
                    .foregroundColor(fullTextMode ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(fullTextMode ? "Switch to compact view" : "Switch to full-text view")

            Button(action: { startCreatingNote() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Create new note (⌘N)")

            Button(action: { loadNotes() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh notes")

            Button(action: openInFinder) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open notes folder")

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

            TextField("Search notes...", text: $searchText)
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

    // MARK: - Notes List

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: fullTextMode ? 12 : 8) {
                ForEach(filteredNotes) { note in
                    NoteRowView(
                        note: note,
                        isSelected: selectedNote?.id == note.id,
                        fullTextMode: fullTextMode,
                        isCollapsed: isNoteCollapsed(note),
                        collapseThreshold: collapseThreshold,
                        onToggleCollapse: { toggleNoteCollapsed(note) }
                    )
                    .onTapGesture {
                        selectedNote = note
                        // In compact mode, open the view sheet
                        if !fullTextMode {
                            viewingNote = note
                        }
                    }
                    .contextMenu {
                        Button("View Note") {
                            viewingNote = note
                        }
                        Button("Copy to Clipboard") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.content, forType: .string)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(note.url.path, inFileViewerRootedAtPath: "")
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            deleteNote(note)
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
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Notes Yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("Say \"take a note\" followed by your note content")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)

            Button(action: { startCreatingNote() }) {
                Label("Create Note", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("Or use voice commands:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\"take a note [text]\"")
                Text("\"voiceflow make a long note\"")
                Text("\"voiceflow start making a note\"")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.7))
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func startCreatingNote() {
        newNoteText = ""
        isCreatingNote = true
    }

    private func saveNewNote() {
        let trimmedText = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Create notes directory if needed
        if !FileManager.default.fileExists(atPath: notesDirectory.path) {
            try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        }

        // Generate filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "Note_\(formatter.string(from: Date())).txt"
        let fileURL = notesDirectory.appendingPathComponent(filename)

        do {
            try trimmedText.write(to: fileURL, atomically: true, encoding: .utf8)
            NSLog("[VoiceFlow] Created new note: \(filename)")
            isCreatingNote = false
            newNoteText = ""
            loadNotes() // Refresh the list
        } catch {
            NSLog("[VoiceFlow] Error saving note: \(error)")
        }
    }

    private func loadNotes() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var loadedNotes: [NoteFile] = []

            if FileManager.default.fileExists(atPath: notesDirectory.path) {
                do {
                    let files = try FileManager.default.contentsOfDirectory(
                        at: notesDirectory,
                        includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                        options: [.skipsHiddenFiles]
                    )

                    for fileURL in files where fileURL.pathExtension == "txt" {
                        if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                           let date = attrs[.creationDate] as? Date {
                            loadedNotes.append(NoteFile(
                                url: fileURL,
                                name: fileURL.lastPathComponent,
                                content: content,
                                date: date
                            ))
                        }
                    }
                } catch {
                    NSLog("[VoiceFlow] Error loading notes: \(error)")
                }
            }

            // Sort by date, newest first
            loadedNotes.sort { $0.date > $1.date }

            DispatchQueue.main.async {
                self.notes = loadedNotes
                self.isLoading = false
            }
        }
    }

    private func deleteNote(_ note: NoteFile) {
        do {
            try FileManager.default.removeItem(at: note.url)
            notes.removeAll { $0.id == note.id }
            if selectedNote?.id == note.id {
                selectedNote = nil
            }
            // Cleanup collapse state
            cleanupCollapseState(for: note)
        } catch {
            NSLog("[VoiceFlow] Error deleting note: \(error)")
        }
    }

    private func openInFinder() {
        NSWorkspace.shared.open(notesDirectory)
    }

    private func closePanel() {
        appState.isNotesPanelVisible = false
    }
}

// MARK: - Note File Model

struct NoteFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let content: String
    let date: Date

    var preview: String {
        let lines = content.components(separatedBy: .newlines)
        let firstLine = lines.first ?? ""
        if firstLine.count > 100 {
            return String(firstLine.prefix(100)) + "..."
        }
        return firstLine
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Note Row View

struct NoteRowView: View {
    let note: NoteFile
    let isSelected: Bool
    var fullTextMode: Bool = false
    var isCollapsed: Bool = false
    var collapseThreshold: Int = 200
    var onToggleCollapse: (() -> Void)?

    private var shouldShowCollapseButton: Bool {
        fullTextMode && note.content.count > collapseThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fullTextMode {
                // Full-text mode: show entire content or collapsed
                if isCollapsed {
                    Text(note.preview)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                } else {
                    Text(note.content)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }

                HStack {
                    Text(note.formattedDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Spacer()

                    if shouldShowCollapseButton {
                        Button(action: { onToggleCollapse?() }) {
                            Text(isCollapsed ? "Expand" : "Collapse")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Compact mode: show preview only
                Text(note.preview)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Text(note.formattedDate)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .textBackgroundColor).opacity(0.3))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Visual Effect View

struct NotesVisualEffectView: NSViewRepresentable {
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
