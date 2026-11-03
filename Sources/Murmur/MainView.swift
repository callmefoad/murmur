import AppKit
import Combine
import Speech
import SwiftUI
import UniformTypeIdentifiers

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
                Label(
                    app.isPolishedRecording ? "Recording — Polished" : "Recording…",
                    systemImage: app.isPolishedRecording ? "wand.and.stars" : "waveform")
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
                Text("Speech and text stay on-device. Updates and optional model downloads use the network.")
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
func compactNumber(_ number: Int) -> String {
    number >= 1000
        ? String(format: "%.1fK", Double(number) / 1000)
        : "\(number)"
}
