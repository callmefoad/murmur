import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette (Murmur: warm paper, soft teal, adaptive light/dark)

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
        })
    }

    /// Warm backdrop behind the sidebar and panel.
    static let shell = dynamic(
        NSColor(red: 0.962, green: 0.954, blue: 0.940, alpha: 1),
        NSColor(red: 0.125, green: 0.123, blue: 0.118, alpha: 1))
    /// The main content sheet.
    static let panel = dynamic(
        .white,
        NSColor(red: 0.168, green: 0.165, blue: 0.160, alpha: 1))
    /// Cards on the sheet.
    static let card = dynamic(
        NSColor(red: 0.972, green: 0.965, blue: 0.952, alpha: 1),
        NSColor(red: 0.208, green: 0.204, blue: 0.198, alpha: 1))
    /// The promo banner — deep calm teal in both modes.
    static let banner = dynamic(
        NSColor(red: 0.078, green: 0.153, blue: 0.146, alpha: 1),
        NSColor(red: 0.096, green: 0.176, blue: 0.168, alpha: 1))
    /// Soft seafoam tint for callout cards.
    static let tint = dynamic(
        NSColor(red: 0.886, green: 0.938, blue: 0.925, alpha: 1),
        NSColor(red: 0.157, green: 0.235, blue: 0.224, alpha: 1))
    /// Primary text / filled buttons.
    static let ink = dynamic(
        NSColor(red: 0.13, green: 0.13, blue: 0.135, alpha: 1),
        NSColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1))
    /// Text on top of an ink-filled control.
    static let onInk = dynamic(
        .white,
        NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1))
    static let border = dynamic(
        NSColor.black.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0.12))
    /// Murmur's accent: a soft teal.
    static let accent = dynamic(
        NSColor(red: 0.16, green: 0.55, blue: 0.52, alpha: 1),
        NSColor(red: 0.40, green: 0.78, blue: 0.74, alpha: 1))
}

// MARK: - Card chrome

extension View {
    /// The standard settings card: full width, 20pt inset, rounded fill.
    ///
    /// Written out eleven times before this existed, which meant the corner
    /// radius and the inset were eleven separate decisions that happened to
    /// agree. A handful of cards still set their own padding or a minimum
    /// height and are left inline, because they genuinely differ.
    func card() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Pages

enum Page: Hashable {
    case home, insights, dictionary, training, snippets, myVoice, style
    case transforms, scratchpad
    case settings, help

    var label: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .training: return "Voice Training"
        case .snippets: return "Snippets"
        case .myVoice: return "My Voice"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .insights: return "chart.bar"
        case .dictionary: return "text.book.closed"
        case .training: return "waveform.badge.mic"
        case .snippets: return "scissors"
        case .myVoice: return "person.wave.2"
        case .style: return "textformat"
        case .transforms: return "wand.and.sparkles"
        case .scratchpad: return "square.and.pencil"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }

    static let mainItems: [Page] = [
        .home, .insights, .dictionary, .training, .snippets, .myVoice, .style,
        .transforms, .scratchpad,
    ]
    static let bottomItems: [Page] = [.settings, .help]
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var app: AppDelegate
    @State private var page: Page = .home
    @State private var showSidebar = true

    private let permissionTimer = Timer.publish(
        every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(app: app, page: $page, showSidebar: $showSidebar)
                    .frame(width: 232)
            }
            mainPanel
        }
        .background(Palette.shell)
        .ignoresSafeArea()
        .onReceive(permissionTimer) { _ in app.refreshPermissions() }
        
    }

    private var mainPanel: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.panel)
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    pageContent
                        .padding(.horizontal, 56)
                        .padding(.bottom, 40)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: showSidebar ? 0 : 6, bottom: 6, trailing: 6))
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if !showSidebar {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 76)
            }
            Spacer()
            if let status = app.transformStatus {
                Label(status, systemImage: "wand.and.sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accent)
            }
            if let error = app.lastError, app.uiState == .idle {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 460, alignment: .trailing)
            }
            RecordingPill(app: app)
            Image(systemName: "bell")
                .foregroundStyle(Palette.ink.opacity(0.75))
                .onTapGesture { page = .help }
            Image(systemName: "person.circle")
                .font(.system(size: 18))
                .foregroundStyle(Palette.ink.opacity(0.75))
                .onTapGesture { page = .settings }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .home: HomePage(app: app, page: $page)
        case .insights: InsightsPage(app: app)
        case .dictionary: DictionaryPage()
        case .training: TrainingPage(app: app)
        case .snippets: SnippetsPage()
        case .myVoice: MyVoicePage(app: app, voiceStore: app.voiceStore)
        case .style: StylePage(app: app)
        case .transforms: TransformsPage(app: app)
        case .scratchpad: ScratchpadPage()
        case .settings: SettingsPage(app: app)
        case .help: HelpPage(app: app)
        }
    }
}

// MARK: - Recording status pill (top bar)

struct RecordingPill: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        Group {
            switch app.uiState {
            case .idle:
                EmptyView()
            case .recording:
                Label(app.isHandsFree ? "Recording — hands-free" : "Recording…",
                      systemImage: "waveform")
                    .foregroundStyle(.red)
            case .processing:
                Label("Transcribing…", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.medium))
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .bold))
                Text("Murmur")
                    .font(.system(size: 22, weight: .semibold))
                Text("Local")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Palette.border, lineWidth: 1))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(Page.mainItems, id: \.self) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            wordsCard
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(Page.bottomItems, id: \.self) { item in
                    navRow(item, compact: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(Palette.shell)
    }

    private func navRow(_ item: Page, compact: Bool = false) -> some View {
        let selected = page == item
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: compact ? 13 : 14))
                .frame(width: 20)
            Text(item.label)
                .font(.system(size: compact ? 13 : 14,
                              weight: selected ? .medium : .regular))
            Spacer()
        }
        .foregroundStyle(Palette.ink.opacity(selected ? 1 : 0.8))
        .padding(.vertical, compact ? 6 : 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Palette.panel : .clear)
                .shadow(color: selected ? .black.opacity(0.06) : .clear,
                        radius: 2, y: 1))
        .contentShape(Rectangle())
        .onTapGesture { page = item }
    }

    private var wordsCard: some View {
        let missingNames = [
            app.micAuthorized ? nil : "Microphone",
            app.axTrusted ? nil : "Accessibility",
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 8) {
            if !missingNames.isEmpty {
                Text("\(missingNames.count) permission\(missingNames.count == 1 ? "" : "s") needed")
                    .font(.system(size: 14, weight: .semibold))
                Text("Grant \(missingNames.joined(separator: " and ")) to start dictating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { page = .settings } label: {
                    Text("Fix now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                Text("∞ words remaining")
                    .font(.system(size: 14, weight: .semibold))
                Text("Everything runs on-device. Unlimited, free, private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { page = .help } label: {
                    Text("How it works")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Shared compact formatter for large stat counts (e.g. "1.2K").
fileprivate func compactNumber(_ number: Int) -> String {
    number >= 1000
        ? String(format: "%.1fK", Double(number) / 1000)
        : "\(number)"
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var searchText = ""
    @State private var searchOpen = false
    @State private var showClearConfirm = false
    @State private var hoveredRow: String?
    @State private var editingEntry: HistoryEntry?
    @State private var editText = ""
    @State private var learnFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Welcome back, \(firstName)")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 24) {
                    banner
                    historyFeed
                }
                VStack(spacing: 16) {
                    statsCard
                    voiceProfileCard
                }
                .frame(width: 300)
            }
        }
        .sheet(item: $editingEntry) { entry in
            VStack(alignment: .leading, spacing: 14) {
                Label("Correct this transcript", systemImage: "pencil")
                    .font(.headline)
                Text("Fix what Murmur misheard. It compares your fix with the " +
                     "original and learns the corrections for future dictations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(width: 460, height: 140)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Spacer()
                    Button("Cancel") { editingEntry = nil }
                    Button("Save & Learn") {
                        // Copy sheet state first: it resets when the sheet
                        // is dismissed below, and learning now completes
                        // asynchronously off the main actor.
                        let editedID = entry.id
                        let newText = editText
                        Task {
                            let learnedCount = await app.correctHistoryEntry(
                                id: editedID, newText: newText)
                            learnFeedback = learnedCount > 0
                                ? "Learned \(learnedCount) correction" +
                                  "\(learnedCount == 1 ? "" : "s") from your fix."
                                : "Transcript updated."
                            editingEntry = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    // MARK: Banner

    private var banner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.banner)
            HStack {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 150, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Palette.accent.opacity(0.55), .white.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(.trailing, 40)
            }
            VStack(alignment: .leading, spacing: 10) {
                (Text("Make Murmur sound like ")
                    + Text("you").italic())
                    .font(.system(size: 32, design: .serif))
                    .foregroundStyle(.white)
                Text("Teach it your names, jargon and spellings.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                Button { page = .training } label: {
                    Text("Start now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(.white.opacity(0.35), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
        .frame(height: 224)
    }

    // MARK: Stats

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            statRow(compactNumber(app.stats.words), "total words")
            statRow(wpmText, "wpm")
            statRow("\(app.dayStreak)", "day streak")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statRow(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value)
                .font(.system(size: 32, design: .serif))
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private var wpmText: String {
        guard let wpm = app.wordsPerMinute else { return "—" }
        return "\(wpm)"
    }

    // MARK: Voice profile card

    private var voiceProfileCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice Profile")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                    .textCase(.uppercase)
                if let profile = app.voiceProfile {
                    Text(profile.title)
                        .font(.system(size: 22, design: .serif))
                    if !profile.summary.isEmpty {
                        Text(profile.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Still listening…")
                        .font(.system(size: 22, design: .serif))
                    Text("Dictate a bit more and Murmur will sketch your " +
                         "persona from what you talk about.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text((Locale.current.localizedString(
                    forIdentifier: app.localeID) ?? app.localeID)
                    + " · Hold \(app.hotkey.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text("Click to train your pronunciation")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 12) {
                Image(systemName: "figure.wave")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.accent)
                if app.voiceProfile != nil {
                    Button {
                        app.refreshVoiceProfileIfDue(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh profile from your latest dictations")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { page = .training }
    }

    // MARK: History feed

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.entries }
        return app.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [(title: String, items: [HistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredEntries) {
            calendar.startOfDay(for: $0.date)
        }
        return groups.keys.sorted(by: >).map { day in
            (dayLabel(day), groups[day]!.sorted { $0.date > $1.date })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    // MARK: History export

    private enum HistoryExportFormat {
        case json, markdown

        var fileExtension: String { self == .json ? "json" : "md" }
    }

    /// Runs a save panel and writes every stored transcript in the chosen
    /// format. Failures surface through the same `lastError` caption the
    /// rest of the app uses (plus a notification if the window is closed).
    private func exportHistory(_ format: HistoryExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .json
                ? .json
                : UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.nameFieldStringValue = "murmur-history.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case .json:
                data = try app.exportHistoryJSONData()
            case .markdown:
                data = Data(app.exportHistoryMarkdown().utf8)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            app.lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    private var historyFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedback = learnFeedback {
                Label(feedback, systemImage: "graduationcap")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accent)
                    .task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        learnFeedback = nil
                    }
            }
            if app.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No transcripts yet")
                        .font(.headline)
                    Text("Click into any text field, hold \(app.hotkey.displayName), " +
                         "and speak. Your dictations will show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else {
                historyHeaderRow

                if sections.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("No matches for \u{201C}\(searchText)\u{201D}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        HStack {
                            Text(section.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .kerning(0.8)
                            Spacer()
                        }
                        .padding(.top, index == 0 ? 0 : 14)

                        VStack(spacing: 0) {
                            ForEach(section.items) { entry in
                                historyRow(entry)
                                if entry != section.items.last {
                                    Divider().opacity(0.6)
                                }
                            }
                        }
                        .background(Palette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Palette.border, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var historyHeaderRow: some View {
        HStack {
            Spacer()
            if searchOpen {
                TextField("Search transcripts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Button {
                searchOpen.toggle()
                if !searchOpen { searchText = "" }
            } label: {
                Image(systemName: searchOpen
                    ? "xmark.circle" : "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Menu {
                Button("Export JSON…") { exportHistory(.json) }
                Button("Export Markdown…") { exportHistory(.markdown) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export history")
            Button {
                showClearConfirm = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear all history")
            .confirmationDialog(
                "Clear all history?", isPresented: $showClearConfirm) {
                Button("Clear History", role: .destructive) {
                    app.clearHistoryEntries()
                }
            } message: {
                Text("This permanently deletes all \(app.entries.count) " +
                     "saved transcripts. This can't be undone.")
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let hovered = hoveredRow == entry.id
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .leading)
            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 14))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovered {
                HStack(spacing: 14) {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(entry.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    Button {
                        editText = entry.text
                        editingEntry = entry
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .help("Correct — Murmur learns from your fix")
                    Button {
                        app.deleteHistoryEntry(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hovered ? Color.black.opacity(0.025) : .clear)
        .onHover { inside in
            hoveredRow = inside ? entry.id : (hoveredRow == entry.id ? nil : hoveredRow)
        }
    }
}

// MARK: - Insights

struct InsightsPage: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Insights")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            HStack(spacing: 16) {
                tile("\(app.stats.dictations)", "dictations")
                tile(compactNumber(app.stats.words), "total words")
                tile(avgWords, "avg words / dictation")
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Words per day — last 7 days")
                    .font(.headline)
                chart
                if last7Days.contains(where: \.hasUnknownCount) {
                    Text("Hatched bars had a dictation that day, but it " +
                         "was recorded before Murmur tracked per-day word " +
                         "counts — lifetime totals above still count it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        }
    }

    private var avgWords: String {
        app.stats.dictations == 0 ? "—" : "\(app.stats.words / app.stats.dictations)"
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 32, design: .serif))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Fixed-format day key matching `StatsStore`'s internal format, so
    /// `app.stats.dailyWords` can be looked up from here without reaching
    /// into that private formatter.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Driven by `app.stats.dailyWords` (lifetime, uncapped) rather than
    /// `app.entries` (which `HistoryStore` caps at 50), so a heavy day no
    /// longer evicts older days into a fake zero. A day can still show 0
    /// words while `hasUnknownCount` is true: that's a day migrated from an
    /// older `stats.json` that only recorded which days were active, not
    /// per-day counts (see `LifetimeStats.init(from:)`) — a real data gap,
    /// not a bug, so it's rendered distinctly rather than as a bare zero.
    private var last7Days: [(day: Date, words: Int, hasUnknownCount: Bool)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = Self.dayKeyFormatter.string(from: day)
            let words = app.stats.dailyWords[key] ?? 0
            let wasActive = app.stats.dailyWords[key] != nil
            return (day, words, wasActive && words == 0)
        }
    }

    private var chart: some View {
        let data = last7Days
        let maxWords = max(data.map(\.words).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(data, id: \.day) { point in
                VStack(spacing: 6) {
                    Text(point.words > 0 ? "\(point.words)" : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if point.hasUnknownCount {
                        // A dictation happened that day, but it predates
                        // per-day word tracking — show a small hatched
                        // marker rather than a fabricated bar height or a
                        // bar that's visually identical to a truly empty
                        // day.
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Palette.accent, lineWidth: 1.5,
                                          antialiased: true)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Palette.accent.opacity(0.12)))
                            .frame(height: 16)
                            .help("Dictated that day — recorded before " +
                                  "per-day word counts were tracked.")
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(point.words > 0 ? Palette.accent : Palette.border)
                            .frame(height: max(6,
                                CGFloat(point.words) / CGFloat(maxWords) * 140))
                    }
                    Text(point.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 190, alignment: .bottom)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @State private var rows: [DictionaryRow] = []
    @State private var newSpoken = ""
    @State private var newReplacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictionary")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Spoken phrases are replaced in every transcript, " +
                 "so names and jargon come out spelled your way.")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach($rows) { $row in
                    HStack {
                        TextField("spoken phrase", text: $row.spoken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        if isDuplicateSpoken(row) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Duplicate spoken phrase — only one " +
                                      "entry will be saved.")
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("replacement", text: $row.replacement)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        Button {
                            rows.removeAll { $0.id == row.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("new spoken phrase", text: $newSpoken)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("replacement", text: $newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button { add() } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                              || isDuplicateNewSpoken)
                    .help(isDuplicateNewSpoken
                          ? "That spoken phrase already has an entry." : "")
                }
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear(perform: load)
    }

    /// Normalized (trimmed, lowercased) spoken phrases that appear on more
    /// than one row. The dictionary is persisted as `[String: String]`, so
    /// duplicate spoken keys silently collapse to one entry on save — this
    /// can't be fixed from MainView without changing that storage format
    /// (owned by another agent), so instead duplicates are surfaced in the
    /// UI and adding a new one is blocked.
    private var duplicateSpokenKeys: Set<String> {
        let normalized = rows.map {
            $0.spoken.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for key in normalized { counts[key, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func isDuplicateSpoken(_ row: DictionaryRow) -> Bool {
        duplicateSpokenKeys.contains(
            row.spoken.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private var isDuplicateNewSpoken: Bool {
        let normalized = newSpoken.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return false }
        return rows.contains {
            $0.spoken.trimmingCharacters(in: .whitespaces).lowercased() == normalized
        }
    }

    private func add() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !isDuplicateNewSpoken else { return }
        rows.append(DictionaryRow(
            spoken: spoken,
            replacement: newReplacement.trimmingCharacters(in: .whitespaces)))
        newSpoken = ""
        newReplacement = ""
        save()
    }

    private func load() {
        rows = TextFormatter.loadDictionary()
            .sorted { $0.key < $1.key }
            .map { DictionaryRow(spoken: $0.key, replacement: $0.value) }
    }

    private func save() {
        // Blank-spoken rows are persisted as-is rather than dropped here:
        // PhraseReplacer (used by TextFormatter.applyDictionary) already
        // ignores empty/whitespace-only keys at apply time, so saving them
        // is safe and avoids silently discarding a row's replacement text
        // while the user is mid-retype of its spoken phrase.
        var dictionary: [String: String] = [:]
        for row in rows {
            dictionary[row.spoken.trimmingCharacters(in: .whitespaces)] = row.replacement
        }
        if let data = try? JSONEncoder().encode(dictionary) {
            try? data.write(to: TextFormatter.dictionaryURL, options: .atomic)
            AppPaths.secure(TextFormatter.dictionaryURL)
        }
    }
}

struct DictionaryRow: Identifiable {
    let id = UUID()
    var spoken: String
    var replacement: String
}

// MARK: - Scratchpad

struct ScratchpadPage: View {
    @State private var text = ""

    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("scratchpad.txt")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Scratchpad")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("A place to park text. Saved automatically.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(16)
                .frame(minHeight: 380)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
        .onChange(of: text) { _, newValue in
            try? newValue.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var supportedLocaleIDs: [String] = []
    @State private var whisperModelDownloaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions").font(.headline)
                permissionRow(
                    granted: app.micAuthorized,
                    title: "Microphone",
                    detail: "Required to hear your dictation.",
                    pane: "Privacy_Microphone")
                Divider()
                permissionRow(
                    granted: app.axTrusted,
                    title: "Accessibility",
                    detail: "Required for the global hotkey and pasting. " +
                            "Relaunch Murmur after granting.",
                    pane: "Privacy_Accessibility")
                if !app.axTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Toggle on in System Settings but still red here? " +
                             "The saved grant belongs to an older build. Click " +
                             "Reset Grant — the app relaunches, macOS asks once " +
                             "more, and the new grant sticks for all future updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Grant & Relaunch") {
                            app.resetAccessibilityGrant()
                        }
                        Button("Relaunch") { app.relaunch() }
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Dictation").font(.headline)
                HStack {
                    Text("Dictation key")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.hotkey },
                        set: { app.setHotkey($0) })) {
                        ForEach(HotkeyMonitor.Hotkey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.localeID },
                        set: { app.setLocale($0) })) {
                        ForEach(pickerLocaleIDs, id: \.self) { identifier in
                            Text(Locale.current.localizedString(
                                forIdentifier: identifier) ?? identifier)
                                .tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recognition engine")
                        Text(app.engine == "whisper"
                            ? "Whisper: best accuracy on accents and jargon; " +
                              "your vocabulary is fed to the model. Runs locally."
                            : "Apple: instant, built into macOS. Runs locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.engine },
                        set: { app.setEngine($0) })) {
                        Text("Apple — instant").tag("apple")
                        Text("Whisper — precise").tag("whisper")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if app.engine == "whisper" {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whisper model")
                            Text(app.whisperReady
                                ? "Model loaded — Whisper is transcribing your dictations."
                                : whisperModelDownloaded
                                    ? "Model downloaded — loading. Apple engine covers " +
                                      "dictations until it's ready."
                                    : "Downloading in the background. Apple engine covers " +
                                      "dictations until it's ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.whisperModel },
                            set: { app.setWhisperModel($0) })) {
                            ForEach(WhisperEngine.availableModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Divider()
                toggleRow(
                    title: "Live caption while dictating",
                    detail: "Shows a floating waveform — and live text when " +
                            "streaming recognition is on — while you dictate.",
                    isOn: Binding(
                        get: { app.liveCaptions },
                        set: { app.setLiveCaptions($0) }))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cleanup level")
                            Text("Cleaned is the default. Polished and Tightened " +
                                 "rewrite with the on-device model, which can " +
                                 "reword more than you intended.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.cleanupLevel },
                            set: { app.setCleanupLevel($0) })) {
                            Text("Verbatim").tag(0)
                            Text("Cleaned").tag(1)
                            Text("Polished").tag(2)
                            Text("Tightened").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text(cleanupStopBlurb(app.cleanupLevel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Voice commands").font(.headline)
                Text("Murmur types what you say. These let it act on what " +
                     "you say instead — it can't tell whether you meant a " +
                     "command or just said the words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toggleRow(
                    title: "Spoken edits",
                    detail: "Off by default. When on, saying \"scratch that\" " +
                            "or \"never mind\" edits or discards what you just " +
                            "dictated — which can fire when you only meant to " +
                            "say those words.",
                    isOn: Binding(
                        get: { app.spokenEdits },
                        set: { app.setSpokenEdits($0) }))
                Divider()
                toggleRow(
                    title: "Spoken layout",
                    detail: "Saying \"new line\" or \"new paragraph\" inserts a " +
                            "break. Turn off if you dictate those words literally.",
                    isOn: Binding(
                        get: { app.spokenLayout },
                        set: { app.setSpokenLayout($0) }))
                Divider()
                toggleRow(
                    title: "Spoken symbols",
                    detail: "Off by default. When on, saying \"period\", " +
                            "\"comma\", \"star\" or \"dash\" inserts the symbol " +
                            "instead of the word. Your recognizer already " +
                            "adds punctuation on its own.",
                    isOn: Binding(
                        get: { app.spokenSymbols },
                        set: { app.setSpokenSymbols($0) }))
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy").font(.headline)
                toggleRow(
                    title: "Pause history",
                    detail: "Transcripts are still inserted, just never written to disk.",
                    isOn: Binding(
                        get: { app.historyPaused },
                        set: { app.setHistoryPaused($0) }))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep history for")
                        Text("Older transcripts are deleted automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.historyRetentionDays },
                        set: { app.setHistoryRetentionDays($0) })) {
                        Text("Forever").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep how many transcripts")
                        Text("Oldest are dropped as new dictations arrive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.historyLimit },
                        set: { app.setHistoryLimit($0) })) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("250").tag(250)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                toggleRow(
                    title: "Add a period automatically",
                    detail: "Turning this off suits search fields, chat, and code.",
                    isOn: Binding(
                        get: { app.autoPeriod },
                        set: { app.setAutoPeriod($0) }))
                Divider()
                toggleRow(
                    title: "Launch at login",
                    detail: "Starts Murmur automatically when you sign in.",
                    isOn: Binding(
                        get: { app.launchAtLogin },
                        set: { app.setLaunchAtLogin($0) }))
                if let note = app.launchAtLoginNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .card()
        }
        .onAppear {
            loadLocales()
            refreshWhisperModelDownloaded()
        }
        .onChange(of: app.whisperModel) { _, _ in refreshWhisperModelDownloaded() }
        .onChange(of: app.engine) { _, _ in refreshWhisperModelDownloaded() }
    }

    /// Recursively walks the Whisper models directory, so it's cached in
    /// `@State` and only recomputed on appear or when the selected engine
    /// or model changes — not from `body`, which the 2s permission-refresh
    /// timer re-evaluates continuously while this page is open.
    private func refreshWhisperModelDownloaded() {
        whisperModelDownloaded = app.whisperEngine.isModelDownloaded(app.whisperModel)
    }

    /// Blurbs come from the shared cleanup-stop enum; `resolve` clamps any
    /// persisted Int so a garbage value still renders the default stop.
    private func cleanupStopBlurb(_ level: Int) -> String {
        CleanupLevel.resolve(level).blurb
    }

    private var pickerLocaleIDs: [String] {
        var ids = supportedLocaleIDs
        if !ids.contains(app.localeID) {
            ids.insert(app.localeID, at: 0)
        }
        return ids
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = locales
                .map { $0.identifier(.bcp47) }
                .sorted {
                    (Locale.current.localizedString(forIdentifier: $0) ?? $0)
                    < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
                }
        }
    }

    private func permissionRow(
        granted: Bool, title: String, detail: String, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
                    let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func toggleRow(
        title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Help

struct HelpPage: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Help")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 14) {
                helpRow("hand.tap", "Push-to-talk",
                    "Click into any text field, hold \(app.hotkey.displayName), speak, " +
                    "release. The cleaned-up text is pasted at your cursor.")
                Divider()
                helpRow("hands.and.sparkles", "Hands-free",
                    "Double-tap \(app.hotkey.displayName) to keep recording without " +
                    "holding. Tap once to stop.")
                Divider()
                helpRow("text.insert", "Voice commands",
                    "Say “new line” or “new paragraph” to add line breaks. " +
                    "Punctuation is added automatically from your pauses and tone.")
                Divider()
                helpRow("lock.shield", "Private by design",
                    "Recognition runs entirely on this Mac using Apple's on-device " +
                    "speech model. No audio or text ever leaves your machine.")
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func helpRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @State private var snippets: [Snippet] = []
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Snippets")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Say the trigger phrase while dictating and the whole block is " +
                 "inserted instead — signatures, addresses, meeting links, " +
                 "canned replies.")
                .foregroundStyle(.secondary)

            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(Palette.accent)
                        TextField("trigger phrase (what you say)",
                                  text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    TextEditor(text: $snippet.expansion)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 64)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                        .onChange(of: snippet.expansion) { _, _ in scheduleSave() }
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add new").font(.headline)
                TextField("trigger phrase (what you say)", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newExpansion)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 64)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Add snippet") {
                        snippets.append(Snippet(
                            trigger: newTrigger.trimmingCharacters(in: .whitespaces),
                            expansion: newExpansion))
                        newTrigger = ""
                        newExpansion = ""
                        save()
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                              || newExpansion.isEmpty)
                }
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { snippets = SnippetStore.load() }
    }

    /// Debounces the per-keystroke expansion edits so a full JSON rewrite
    /// isn't happening on every character — waits for a short pause in
    /// typing before persisting.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        // Blank-trigger rows are persisted as-is rather than dropped here:
        // SnippetStore.expand() already filters empty triggers at expansion
        // time, so saving them is safe and avoids silently discarding a
        // snippet's expansion text while the user is mid-retype of its
        // trigger (e.g. selected-all-deleted the field to type a new one).
        SnippetStore.save(snippets)
    }
}

// MARK: - My Voice

struct MyVoicePage: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var voiceStore: VoiceInstructionStore
    @State private var editingPreset: VoiceInstruction?
    @State private var editingIsNew = false
    @State private var pendingDelete: VoiceInstruction?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("My Voice")
                    .font(.system(size: 30, weight: .medium))
                Spacer()
                Button {
                    newPreset()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("New preset")
            }
            .padding(.top, 24)
            Text("Presets rewrite your dictations before they're inserted — " +
                 "your phrasing, enforced everywhere you talk.")
                .foregroundStyle(.secondary)

            if voiceStore.instructions.isEmpty {
                emptyState
            } else {
                presetList
            }
        }
        .sheet(item: $editingPreset) { preset in
            VoicePresetEditorView(
                preset: preset,
                isNew: editingIsNew,
                onSave: { updated in
                    if editingIsNew {
                        voiceStore.add(updated)
                    } else {
                        voiceStore.update(updated)
                    }
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil })
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
            isPresented: $showDeleteConfirm,
            presenting: pendingDelete) { preset in
            Button("Delete Preset", role: .destructive) {
                voiceStore.remove(id: preset.id)
            }
        } message: { preset in
            Text("This permanently deletes \u{201C}\(preset.name)\u{201D}. " +
                 "This can't be undone.")
        }
    }

    private func newPreset() {
        editingIsNew = true
        editingPreset = VoiceInstruction(name: "", instructions: "")
    }

    // MARK: Empty state

    /// Shown until the first preset exists: what My Voice does plus how a
    /// preset gets activated — menu-bar quick-switcher or per-app bindings.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 28))
                .foregroundStyle(Palette.accent)
            Text("Murmur sounds like everyone. Fix that.")
                .font(.headline)
            Text("A preset is a standing instruction — \u{201C}tighten my phrasing\u{201D}, " +
                 "\u{201C}always contractions\u{201D}, \u{201C}no exclamation marks\u{201D} — applied " +
                 "to your dictations right before they're inserted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Activate one from the menu-bar mic icon under My Voice, or " +
                 "bind it to specific apps and it applies only while those apps " +
                 "are frontmost.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                newPreset()
            } label: {
                Label("Create your first preset", systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Preset list

    private var presetList: some View {
        VStack(spacing: 0) {
            ForEach(Array(voiceStore.instructions.enumerated()),
                    id: \.element.id) { index, preset in
                presetRow(preset)
                if index != voiceStore.instructions.count - 1 {
                    Divider().opacity(0.6)
                }
            }
        }
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Palette.border, lineWidth: 1))
    }

    private func presetRow(_ preset: VoiceInstruction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name.isEmpty ? "Untitled preset" : preset.name)
                    .font(.body.weight(.medium))
                Text(firstLine(of: preset.instructions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(preset.appBundleIDs.isEmpty
                    ? "All apps"
                    : "\(preset.appBundleIDs.count) app" +
                      "\(preset.appBundleIDs.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { preset.isEnabled },
                set: { enabled in
                    var updated = preset
                    updated.isEnabled = enabled
                    voiceStore.update(updated)
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
                .help(preset.isEnabled ? "Enabled" : "Off")
            Button {
                editingIsNew = false
                editingPreset = preset
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button {
                pendingDelete = preset
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func firstLine(of text: String) -> String {
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { !$0.isEmpty }) else {
            return "No instructions yet"
        }
        return line
    }
}

/// Create/edit sheet for one My Voice preset: name, freeform rewriting
/// instructions with a placeholder hint, and per-app bindings.
private struct VoicePresetEditorView: View {
    let preset: VoiceInstruction
    let isNew: Bool
    let onSave: (VoiceInstruction) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var appBundleIDs: [String]
    // Cheap placeholders like StylePage's — NSWorkspace enumeration is an
    // AppKit round-trip, so it's cached in @State on appear instead of
    // re-running on every body evaluation.
    @State private var runningAppsList: [(bundleID: String, name: String)] = []
    @State private var manualBundleID = ""

    init(preset: VoiceInstruction, isNew: Bool,
         onSave: @escaping (VoiceInstruction) -> Void,
         onCancel: @escaping () -> Void) {
        self.preset = preset
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: preset.name)
        _instructions = State(initialValue: preset.instructions)
        _appBundleIDs = State(initialValue: preset.appBundleIDs)
    }

    private static let instructionsHint =
        "e.g. Tighten my phrasing. Always contractions. No exclamation " +
        "marks. Keep lists as bullets."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isNew ? "New Preset" : "Edit Preset",
                  systemImage: isNew ? "plus.circle" : "pencil")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.subheadline.weight(.medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 120)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                    if instructions.isEmpty {
                        Text(Self.instructionsHint)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                Text("Applied to every matching dictation right before it's " +
                     "inserted — Murmur rewrites what you dictated to follow " +
                     "these rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Applies to").font(.subheadline.weight(.medium))
                if appBundleIDs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                        Text("All apps").font(.callout)
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                        alignment: .leading, spacing: 8) {
                        ForEach(appBundleIDs, id: \.self) { bundleID in
                            bindingChip(bundleID)
                        }
                    }
                }
                Text("With no bindings a preset applies everywhere; bound ones " +
                     "apply only while that app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Menu {
                        ForEach(runningAppsList, id: \.bundleID) { appInfo in
                            Button(appInfo.name) { addBinding(appInfo.bundleID) }
                                .disabled(appBundleIDs.contains(appInfo.bundleID))
                        }
                    } label: {
                        Label("Add app…", systemImage: "plus")
                    }
                    .fixedSize()
                    TextField("or paste a bundle ID, e.g. com.apple.Notes",
                              text: $manualBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addManual)
                    Button("Add", action: addManual)
                        .disabled(manualBundleID
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Create Preset" : "Save Changes") {
                    onSave(VoiceInstruction(
                        id: preset.id,
                        name: name.trimmingCharacters(in: .whitespaces),
                        instructions: instructions,
                        isEnabled: preset.isEnabled,
                        appBundleIDs: appBundleIDs,
                        createdAt: preset.createdAt))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          instructions.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: refreshRunningApps)
    }

    private func bindingChip(_ bundleID: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "app")
                .foregroundStyle(Palette.accent)
            Text(Self.displayName(forBundleID: bundleID))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                appBundleIDs.removeAll { $0 == bundleID }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Palette.border, lineWidth: 1))
    }

    private func addManual() {
        addBinding(manualBundleID.trimmingCharacters(in: .whitespaces))
        manualBundleID = ""
    }

    private func addBinding(_ bundleID: String) {
        guard !bundleID.isEmpty, !appBundleIDs.contains(bundleID) else { return }
        appBundleIDs.append(bundleID)
    }

    private func refreshRunningApps() {
        runningAppsList = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }

    /// Friendly app name for a stored bundle ID; falls back to the raw id
    /// when no installed app matches (e.g. uninstalled or hand-typed).
    static func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
               ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
               ?? bundle.infoDictionary?["CFBundleName"] as? String,
           !name.isEmpty {
            return name
        }
        return bundleID
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var app: AppDelegate
    // Cheap placeholders — the real values are UserDefaults reads + JSON
    // decodes, so they're loaded once in `.onAppear` rather than in this
    // initializer, which would otherwise re-run (and be discarded) every
    // time this view's parent reconstructs it, including on every tick of
    // the 2s permission-refresh timer while this page is open.
    @State private var defaultStyle: WritingStyle = .none
    @State private var overrides: [String: AppStyleRule] = [:]
    @State private var pickedBundleID: String = ""
    @State private var runningAppsList: [(bundleID: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Style")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Murmur adapts your tone to where you're writing — formal in docs, " +
                 "casual in chat. Rewriting runs on-device with Apple Intelligence.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Default style").font(.headline)
                Text("Used in every app unless overridden below.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $defaultStyle) {
                    ForEach(WritingStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: defaultStyle) { _, newValue in
                    StyleSettings.defaultStyle = newValue
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Per-app styles").font(.headline)
                if overrides.isEmpty {
                    Text("No app rules yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(overrides.sorted(by: { $0.value.appName < $1.value.appName }),
                        id: \.key) { bundleID, rule in
                    HStack {
                        Text(rule.appName)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { rule.style },
                            set: { newStyle in
                                overrides[bundleID] = AppStyleRule(
                                    appName: rule.appName, style: newStyle)
                                StyleSettings.overrides = overrides
                            })) {
                            ForEach(WritingStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            overrides.removeValue(forKey: bundleID)
                            StyleSettings.overrides = overrides
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
                HStack {
                    Picker("", selection: $pickedBundleID) {
                        Text("Choose a running app…").tag("")
                        ForEach(runningAppsList, id: \.bundleID) { appInfo in
                            Text(appInfo.name).tag(appInfo.bundleID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add rule") {
                        guard let appInfo = runningAppsList.first(
                            where: { $0.bundleID == pickedBundleID }) else { return }
                        overrides[appInfo.bundleID] = AppStyleRule(
                            appName: appInfo.name, style: .casual)
                        StyleSettings.overrides = overrides
                        pickedBundleID = ""
                    }
                    .disabled(pickedBundleID.isEmpty)
                }
            }
            .card()
        }
        .onAppear {
            defaultStyle = StyleSettings.defaultStyle
            overrides = StyleSettings.overrides
            refreshRunningApps()
        }
    }

    /// Enumerates `NSWorkspace.shared.runningApplications`, so it's cached
    /// in `@State` and only refreshed on appear rather than every `body`
    /// evaluation (see the `.onAppear` comment above).
    private func refreshRunningApps() {
        runningAppsList = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Transforms

struct TransformsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var tryText = ""
    @State private var result = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Transforms")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Select text in any app, press the shortcut, and it's rewritten " +
                 "in place — on-device.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Transform.all) { transform in
                    HStack(alignment: .top) {
                        Text(transform.keyLabel)
                            .font(.system(size: 13, weight: .semibold,
                                          design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.panel,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Palette.border, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transform.name).font(.body.weight(.medium))
                            Text(transform.description)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if transform.id != Transform.all.last?.id {
                        Divider()
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("Try it here").font(.headline)
                TextEditor(text: $tryText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 70)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    ForEach(Transform.all) { transform in
                        Button(transform.name) { runTransform(transform) }
                            .disabled(running || tryText.isEmpty
                                      || !app.rewriteEngine.isAvailable)
                    }
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !result.isEmpty {
                    Text(result)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                }
            }
            .card()
        }
    }

    private func runTransform(_ transform: Transform) {
        running = true
        result = ""
        Task {
            defer { running = false }
            do {
                result = try await app.transformManager.apply(transform, to: tryText)
            } catch {
                result = "Failed: \(error.localizedDescription)"
            }
        }
    }
}


// MARK: - Voice Training

/// Records a short sample, shows what the model heard, and saves the
/// misheard → intended mapping so Murmur learns the user's pronunciation.
@MainActor
final class TrainingModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var heard: String?
    @Published var result: String?

    private let recorder = AudioRecorder()

    func toggle(app: AppDelegate, target: String) {
        if isRecording {
            stop(app: app, target: target)
        } else {
            start()
        }
    }

    private func start() {
        heard = nil
        result = nil
        do {
            try recorder.start()
            isRecording = true
            NSSound(named: "Pop")?.play()
        } catch {
            result = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stop(app: AppDelegate, target: String) {
        isRecording = false
        guard let url = recorder.stop() else { return }
        NSSound(named: "Tink")?.play()
        isProcessing = true
        Task {
            defer {
                isProcessing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let raw = try await app.transcribeRaw(fileAt: url)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                heard = cleaned.isEmpty ? nil : cleaned
                let intended = target.trimmingCharacters(in: .whitespaces)
                guard let heardText = heard else {
                    result = "Nothing was heard — try again, a bit louder."
                    return
                }
                if heardText.lowercased() == intended.lowercased() {
                    LearnedStore.addTerm(intended)
                    result = "Recognized correctly! Added “\(intended)” to your " +
                             "vocabulary so it stays reliable."
                } else {
                    LearnedStore.add(heard: heardText, intended: intended)
                    result = "Learned: “\(heardText)” → “\(intended)”. Murmur will " +
                             "make this correction automatically from now on."
                }
            } catch {
                result = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }
}

struct TrainingPage: View {
    @ObservedObject var app: AppDelegate
    @StateObject private var model = TrainingModel()
    @State private var target = ""
    @State private var learned = LearnedData()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voice Training")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Teach Murmur how you pronounce names and jargon. Type a word, " +
                 "say it, and Murmur learns what it hears from you — the mapping " +
                 "is applied to every future dictation, and the word is fed to " +
                 "the speech model as expected vocabulary.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("Teach a word or phrase").font(.headline)
                HStack(spacing: 10) {
                    TextField("word or phrase, e.g. “Søren” or “Baseten”",
                              text: $target)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.toggle(app: app, target: target)
                    } label: {
                        Label(model.isRecording ? "Stop" : "Record",
                              systemImage: model.isRecording
                                ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundStyle(model.isRecording ? .red : Palette.accent)
                    }
                    .disabled(model.isProcessing || !app.micAuthorized
                              || (!model.isRecording
                                  && target.trimmingCharacters(in: .whitespaces).isEmpty))
                    if model.isProcessing {
                        ProgressView().controlSize(.small)
                    }
                }
                if model.isRecording {
                    Label("Say “\(target)” now, then press Stop.",
                          systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let result = model.result {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(Palette.accent)
                        .onAppear { learned = LearnedStore.load() }
                }
                Text("Tip: repeat a word 2–3 times — different mishearings each " +
                     "become their own correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Learned corrections").font(.headline)
                Text("Also learned automatically when you fix a transcript in " +
                     "History (pencil icon).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if learned.corrections.isEmpty {
                    Text("Nothing learned yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(learned.corrections.reversed()) { correction in
                        HStack {
                            Text("“\(correction.heard)”")
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text("“\(correction.intended)”")
                                .fontWeight(.medium)
                            if correction.timesSeen > 1 {
                                Text("×\(correction.timesSeen)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                var data = LearnedStore.load()
                                data.corrections.removeAll { $0.id == correction.id }
                                LearnedStore.save(data)
                                learned = data
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 13))
                        Divider()
                    }
                }
                if !learned.terms.isEmpty {
                    Text("Vocabulary hints: " + learned.terms.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .card()
        }
        .onAppear { learned = LearnedStore.load() }
    }
}
