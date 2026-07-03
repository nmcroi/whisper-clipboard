import Combine
import SwiftUI

/// The top-level sidebar destinations.
enum SidebarTab: String, Hashable, CaseIterable {
    case home
    case history

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "Geschiedenis"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Shared navigation state so the menu bar can deep-link into a tab (and a
/// specific transcript) from outside the SwiftUI hierarchy.
@MainActor
final class AppNavigation: ObservableObject {
    @Published var tab: SidebarTab = .home
    /// The transcript id to select/open once the history tab appears.
    @Published var pendingTranscriptID: String?

    /// Focuses the history tab, optionally selecting a specific transcript.
    func openHistory(selecting id: String? = nil) {
        tab = .history
        pendingTranscriptID = id
    }
}
