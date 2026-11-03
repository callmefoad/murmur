import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

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
                Text("Make Murmur sound like \(Text("you").italic())")
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
