import Combine
import Core
import Foundation

/// Observable holder for the speech model's install/download status, for the
/// settings and onboarding UI. Bridges the actor-isolated engine to the main
/// actor so SwiftUI can observe changes.
@MainActor
final class EngineModelManager: ObservableObject {
    @Published private(set) var status: ModelAssetStatus = .unknown
    @Published private(set) var isDownloading = false

    private let engine: any TranscriptionEngine
    private let locale: Locale

    init(engine: any TranscriptionEngine, locale: Locale) {
        self.engine = engine
        self.locale = locale
    }

    /// Refreshes `status` from the engine.
    func refresh() async {
        status = await engine.assetStatus(for: locale)
    }

    /// Drives a download, updating `status`/`isDownloading` around it.
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        status = .downloading(progress: 0)
        do {
            try await engine.downloadAssets(for: locale)
            status = await engine.assetStatus(for: locale)
            try? await engine.prepare()
        } catch {
            status = await engine.assetStatus(for: locale)
        }
        isDownloading = false
    }

    var needsDownload: Bool {
        switch status {
        case .needsDownload, .downloading:
            return true
        default:
            return false
        }
    }
}
