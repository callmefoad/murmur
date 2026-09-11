import AppKit
import SwiftUI

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let shell = dynamic(
        NSColor(red: 0.962, green: 0.954, blue: 0.940, alpha: 1),
        NSColor(red: 0.125, green: 0.123, blue: 0.118, alpha: 1))
    static let panel = dynamic(
        .white, NSColor(red: 0.168, green: 0.165, blue: 0.160, alpha: 1))
    static let card = dynamic(
        NSColor(red: 0.972, green: 0.965, blue: 0.952, alpha: 1),
        NSColor(red: 0.208, green: 0.204, blue: 0.198, alpha: 1))
    static let banner = dynamic(
        NSColor(red: 0.078, green: 0.153, blue: 0.146, alpha: 1),
        NSColor(red: 0.096, green: 0.176, blue: 0.168, alpha: 1))
    static let tint = dynamic(
        NSColor(red: 0.886, green: 0.938, blue: 0.925, alpha: 1),
        NSColor(red: 0.157, green: 0.235, blue: 0.224, alpha: 1))
    static let ink = dynamic(
        NSColor(red: 0.13, green: 0.13, blue: 0.135, alpha: 1),
        NSColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1))
    static let onInk = dynamic(
        .white, NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1))
    static let border = dynamic(
        NSColor.black.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0.12))
    static let accent = dynamic(
        NSColor(red: 0.16, green: 0.55, blue: 0.52, alpha: 1),
        NSColor(red: 0.40, green: 0.78, blue: 0.74, alpha: 1))
}

extension View {
    func card() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

enum Page: Hashable {
    case home, insights, dictionary, training, snippets, myVoice, style
    case transforms, scratchpad, settings, help

    var label: String {
        switch self {
        case .home: "Home"
        case .insights: "Insights"
        case .dictionary: "Dictionary"
        case .training: "Voice Training"
        case .snippets: "Snippets"
        case .myVoice: "My Voice"
        case .style: "Style"
        case .transforms: "Transforms"
        case .scratchpad: "Scratchpad"
        case .settings: "Settings"
        case .help: "Help"
        }
    }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .insights: "chart.bar"
        case .dictionary: "text.book.closed"
        case .training: "waveform.badge.mic"
        case .snippets: "scissors"
        case .myVoice: "person.wave.2"
        case .style: "textformat"
        case .transforms: "wand.and.sparkles"
        case .scratchpad: "square.and.pencil"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }

    static let mainItems: [Page] = [
        .home, .insights, .dictionary, .training, .snippets, .myVoice, .style,
        .transforms, .scratchpad,
    ]
    static let bottomItems: [Page] = [.settings, .help]
}
