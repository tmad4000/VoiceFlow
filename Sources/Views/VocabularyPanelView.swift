import SwiftUI
import AppKit

/// Panel for managing custom vocabulary entries
struct VocabularyPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var isAddingEntry: Bool = false
    @State private var editingEntry: VocabularyEntry?
    @State private var newSpokenPhrase: String = ""
    @State private var newWrittenForm: String = ""
    @State private var newCategory: String = ""

    var filteredEntries: [VocabularyEntry] {
        if searchText.isEmpty {
            return appState.customVocabulary
        }
        return appState.customVocabulary.filter {
            $0.spokenPhrase.localizedCaseInsensitiveContains(searchText) ||
            $0.writtenForm.localizedCaseInsensitiveContains(searchText) ||
            ($0.category ?? "").localizedCaseInsensitiveContains(searchText)
        }
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
            if appState.customVocabulary.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResultsState
            } else {
                entriesList
            }
        }
        .background(
            VocabularyVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $isAddingEntry) {
            addEntrySheet
        }
        .sheet(item: $editingEntry) { entry in
            editEntrySheet(entry: entry)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            Text("Custom Vocabulary")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Text("\(appState.customVocabulary.count) entries")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button(action: { isAddingEntry = true }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Add vocabulary entry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("Search vocabulary...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No Custom Vocabulary")
                .font(.system(size: 14, weight: .medium))

            Text("Add words and phrases that should be\ntyped differently than spoken.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Add Entry") {
                isAddingEntry = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(.secondary)

            Text("No matches for \"\(searchText)\"")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entries List

    private var entriesList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredEntries) { entry in
                    VocabularyRowView(
                        entry: entry,
                        onToggle: { toggleEntry(entry) },
                        onEdit: { editingEntry = entry },
                        onDelete: { deleteEntry(entry) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Add Entry Sheet

    private var addEntrySheet: some View {
        VStack(spacing: 16) {
            Text("Add Vocabulary Entry")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Spoken Phrase")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("What you say (e.g., \"jacob cole\")", text: $newSpokenPhrase)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Written Form")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("What gets typed (e.g., \"Jacob Cole\")", text: $newWrittenForm)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Category (Optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("e.g., Names, Technical, etc.", text: $newCategory)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    clearForm()
                    isAddingEntry = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Add") {
                    addEntry()
                }
                .keyboardShortcut(.return)
                .disabled(newSpokenPhrase.isEmpty || newWrittenForm.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    // MARK: - Edit Entry Sheet

    private func editEntrySheet(entry: VocabularyEntry) -> some View {
        EditVocabularyEntryView(
            entry: entry,
            onSave: { updated in
                appState.updateVocabularyEntry(updated)
                editingEntry = nil
            },
            onCancel: {
                editingEntry = nil
            }
        )
    }

    // MARK: - Actions

    private func addEntry() {
        let entry = VocabularyEntry(
            spokenPhrase: newSpokenPhrase.trimmingCharacters(in: .whitespacesAndNewlines),
            writtenForm: newWrittenForm.trimmingCharacters(in: .whitespacesAndNewlines),
            category: newCategory.isEmpty ? nil : newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        appState.addVocabularyEntry(entry)
        clearForm()
        isAddingEntry = false
    }

    private func clearForm() {
        newSpokenPhrase = ""
        newWrittenForm = ""
        newCategory = ""
    }

    private func toggleEntry(_ entry: VocabularyEntry) {
        var updated = entry
        updated.isEnabled.toggle()
        appState.updateVocabularyEntry(updated)
    }

    private func deleteEntry(_ entry: VocabularyEntry) {
        appState.deleteVocabularyEntry(entry)
    }
}

// MARK: - Row View

struct VocabularyRowView: View {
    let entry: VocabularyEntry
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Enable/disable toggle
            Button(action: onToggle) {
                Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(entry.isEnabled ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.spokenPhrase)
                        .font(.system(size: 12))
                        .foregroundColor(entry.isEnabled ? .primary : .secondary)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(entry.writtenForm)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(entry.isEnabled ? .primary : .secondary)
                }

                if let category = entry.category {
                    Text(category)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            Spacer()

            // Actions (visible on hover)
            if isHovered {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Edit entry")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete entry")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button(entry.isEnabled ? "Disable" : "Enable") { onToggle() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Edit Entry View

struct EditVocabularyEntryView: View {
    let entry: VocabularyEntry
    let onSave: (VocabularyEntry) -> Void
    let onCancel: () -> Void

    @State private var spokenPhrase: String
    @State private var writtenForm: String
    @State private var category: String

    init(entry: VocabularyEntry, onSave: @escaping (VocabularyEntry) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onCancel = onCancel
        _spokenPhrase = State(initialValue: entry.spokenPhrase)
        _writtenForm = State(initialValue: entry.writtenForm)
        _category = State(initialValue: entry.category ?? "")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Vocabulary Entry")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Spoken Phrase")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("What you say", text: $spokenPhrase)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Written Form")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("What gets typed", text: $writtenForm)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Category (Optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("e.g., Names, Technical, etc.", text: $category)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    var updated = entry
                    updated.spokenPhrase = spokenPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.writtenForm = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.category = category.isEmpty ? nil : category.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(updated)
                }
                .keyboardShortcut(.return)
                .disabled(spokenPhrase.isEmpty || writtenForm.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}

// MARK: - Visual Effect View

struct VocabularyVisualEffectView: NSViewRepresentable {
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
