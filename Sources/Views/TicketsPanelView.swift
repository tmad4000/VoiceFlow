import SwiftUI
import AppKit

/// Unified panel for viewing and creating VoiceFlow tickets
struct TicketsPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var tickets: [BeadsTicket] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = true
    @State private var isCreatingTicket: Bool = false
    @State private var newTicketTitle: String = ""
    @State private var newTicketType: TicketType = .feature
    @State private var newTicketPriority: Int = 2
    @State private var filterType: TicketFilterType = .all
    @State private var sortOrder: SortOrder = .priority
    @State private var errorMessage: String?

    private let projectPath = "/Users/jacobcole/code/VoiceFlow"

    enum TicketFilterType: String, CaseIterable {
        case all = "All"
        case bug = "Bugs"
        case feature = "Features"
        case task = "Tasks"
    }

    enum TicketType: String, CaseIterable {
        case feature = "feature"
        case bug = "bug"
        case task = "task"
    }

    enum SortOrder: String, CaseIterable {
        case priority = "Priority"
        case newest = "Newest"
        case updated = "Updated"
        case type = "Type"
        case alphabetical = "A-Z"

        /// The beads CLI sort field name
        var beadsField: String {
            switch self {
            case .priority: return "priority"
            case .newest: return "created"
            case .updated: return "updated"
            case .type: return "type"
            case .alphabetical: return "title"
            }
        }

        /// Whether to reverse sort (newest first for dates)
        var reversed: Bool {
            switch self {
            case .newest, .updated: return true
            default: return false
            }
        }
    }

    var filteredTickets: [BeadsTicket] {
        var result = tickets

        // Filter by type (client-side since we fetch all)
        if filterType != .all {
            let typeString = filterType.rawValue.lowercased().dropLast() // "Bugs" -> "bug"
            result = result.filter { $0.type.lowercased() == typeString }
        }

        // Filter by search (client-side)
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sorting is done server-side via bd list --sort
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
                .padding(.top, 28) // Padding for window buttons (traffic lights)

            Divider()

            // Create new ticket (collapsible)
            if isCreatingTicket {
                createTicketForm
                Divider()
            }

            // Filter/Search bar
            filterBar

            Divider()

            // Content
            if isLoading {
                ProgressView("Loading tickets...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tickets.isEmpty {
                emptyState
            } else if filteredTickets.isEmpty {
                noResultsState
            } else {
                ticketsList
            }

            // Error message
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        errorMessage = nil
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            TicketsVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            loadTickets()
        }
        .onChange(of: sortOrder) { _ in
            loadTickets()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("VoiceFlow Tickets")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Text("\(filteredTickets.count) of \(tickets.count)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Sort menu
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by: \(sortOrder.rawValue)")

            Button(action: { withAnimation { isCreatingTicket.toggle() } }) {
                Image(systemName: isCreatingTicket ? "minus" : "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isCreatingTicket ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(isCreatingTicket ? "Cancel new ticket" : "Create new ticket")

            Button(action: loadTickets) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh tickets")

            Button(action: closePanel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Create Ticket Form

    private var createTicketForm: some View {
        VStack(spacing: 10) {
            HStack {
                Text("New Ticket")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            TextField("Title", text: $newTicketTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            HStack(spacing: 12) {
                // Type picker
                HStack(spacing: 4) {
                    Text("Type:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $newTicketType) {
                        ForEach(TicketType.allCases, id: \.self) { type in
                            Text(type.rawValue.capitalized).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }

                // Priority picker
                HStack(spacing: 4) {
                    Text("Priority:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $newTicketPriority) {
                        Text("P0 Critical").tag(0)
                        Text("P1 High").tag(1)
                        Text("P2 Medium").tag(2)
                        Text("P3 Low").tag(3)
                        Text("P4 Backlog").tag(4)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                Spacer()

                Button("Create") {
                    createTicket()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTicketTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))

                TextField("Search tickets...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
            .cornerRadius(6)

            // Type filter
            Picker("", selection: $filterType) {
                ForEach(TicketFilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tickets List

    private var ticketsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredTickets) { ticket in
                    TicketRowView(ticket: ticket)
                        .contextMenu {
                            Button("Copy ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ticket.id, forType: .string)
                            }
                            Button("Copy Title") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ticket.title, forType: .string)
                            }
                            Divider()
                            Button("Show Details") {
                                showTicketDetails(ticket)
                            }
                        }
                }
            }
            .padding(10)
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.green.opacity(0.6))

            Text("No Open Tickets")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Text("All caught up!")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))

            Button(action: { withAnimation { isCreatingTicket = true } }) {
                Label("Create Ticket", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Matching Tickets")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            Button("Clear Filters") {
                searchText = ""
                filterType = .all
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func loadTickets() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            // Use full path to bd and proper environment
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Build command with sort options
            var command = "cd \(projectPath) && bd list --status=open --sort \(sortOrder.beadsField)"
            if sortOrder.reversed {
                command += " --reverse"
            }
            command += " 2>&1"
            process.arguments = ["-l", "-c", command]
            process.standardOutput = pipe
            process.standardError = pipe

            var loadedTickets: [BeadsTicket] = []
            var error: String?

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    loadedTickets = parseTickets(output)
                } else if output.contains("bd: command not found") {
                    error = "beads CLI not found"
                } else {
                    error = "Failed to load tickets"
                }
            } catch {
                NSLog("[VoiceFlow] Failed to load tickets: \(error)")
            }

            DispatchQueue.main.async {
                self.tickets = loadedTickets
                self.errorMessage = error
                self.isLoading = false
            }
        }
    }

    private func parseTickets(_ output: String) -> [BeadsTicket] {
        var tickets: [BeadsTicket] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty else { continue }

            // Parse format: VoiceFlow-ab1z [P1] [bug] open [label] - Title
            // Regex pattern to extract components
            let pattern = #"^(\S+)\s+\[P(\d)\]\s+\[(\w+)\]\s+\w+(?:\s+\[[^\]]+\])*\s+-\s+(.+)$"#

            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {

                let id = String(line[Range(match.range(at: 1), in: line)!])
                let priority = Int(String(line[Range(match.range(at: 2), in: line)!])) ?? 2
                let type = String(line[Range(match.range(at: 3), in: line)!])
                let title = String(line[Range(match.range(at: 4), in: line)!])

                // Extract labels
                var labels: [String] = []
                let labelPattern = #"\[([^\]]+)\]"#
                if let labelRegex = try? NSRegularExpression(pattern: labelPattern, options: []) {
                    let labelMatches = labelRegex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
                    for labelMatch in labelMatches.dropFirst(2) { // Skip priority and type
                        if let range = Range(labelMatch.range(at: 1), in: line) {
                            let label = String(line[range])
                            if label != "open" && !label.hasPrefix("P") {
                                labels.append(label)
                            }
                        }
                    }
                }

                tickets.append(BeadsTicket(
                    id: id,
                    title: title,
                    type: type,
                    priority: priority,
                    labels: labels
                ))
            }
        }

        return tickets
    }

    private func createTicket() {
        let title = newTicketTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "cd \(projectPath) && bd create --title=\"\(escapedTitle)\" --type=\(newTicketType.rawValue) --priority=\(newTicketPriority)"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        appState.triggerCommandFlash(name: "Ticket Created")
                        newTicketTitle = ""
                        isCreatingTicket = false
                        loadTickets() // Refresh
                    } else {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                        errorMessage = "Failed: \(output)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to create ticket"
                }
            }
        }
    }

    private func showTicketDetails(_ ticket: BeadsTicket) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "cd \(projectPath) && bd show \(ticket.id) 2>&1"]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "No details available"

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = ticket.id
                    alert.informativeText = output
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.addButton(withTitle: "Copy")
                    let response = alert.runModal()
                    if response == .alertSecondButtonReturn {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    }
                }
            } catch {
                NSLog("[VoiceFlow] Failed to show ticket: \(error)")
            }
        }
    }

    private func closePanel() {
        appState.isTicketsPanelVisible = false
        // Post notification to actually close the window
        NotificationCenter.default.post(
            name: NSNotification.Name("TicketsPanelDidClose"),
            object: nil
        )
    }
}

// MARK: - Ticket Model

struct BeadsTicket: Identifiable {
    let id: String
    let title: String
    let type: String
    let priority: Int
    let labels: [String]

    var priorityColor: Color {
        switch priority {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .blue
        default: return .gray
        }
    }

    var typeIcon: String {
        switch type.lowercased() {
        case "bug": return "ladybug.fill"
        case "feature": return "sparkles"
        case "task": return "checklist"
        case "epic": return "flag.fill"
        default: return "doc"
        }
    }

    var typeColor: Color {
        switch type.lowercased() {
        case "bug": return .red
        case "feature": return .purple
        case "task": return .blue
        case "epic": return .orange
        default: return .gray
        }
    }
}

// MARK: - Ticket Row View

struct TicketRowView: View {
    let ticket: BeadsTicket

    var body: some View {
        HStack(spacing: 8) {
            // Priority indicator
            Circle()
                .fill(ticket.priorityColor)
                .frame(width: 8, height: 8)

            // Type icon
            Image(systemName: ticket.typeIcon)
                .font(.system(size: 10))
                .foregroundColor(ticket.typeColor)
                .frame(width: 16)

            // ID
            Text(ticket.id)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            // Title
            Text(ticket.title)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()

            // Labels
            HStack(spacing: 4) {
                ForEach(ticket.labels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Visual Effect View

struct TicketsVisualEffectView: NSViewRepresentable {
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
