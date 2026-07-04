import Combine
import Core
import Foundation
import WhisperShared

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
    ///
    /// The engine reports live progress via its own `assetStatus`, so we poll it
    /// on a short cadence while the download runs and mirror it into `status`
    /// for the UI's progress bar.
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        status = .downloading(progress: 0)

        // Poll the engine's asset status for live download progress.
        let poller = Task { [engine, locale] in
            while !Task.isCancelled {
                let live = await engine.assetStatus(for: locale)
                await MainActor.run {
                    if case .downloading = live { self.status = live }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        do {
            try await engine.downloadAssets(for: locale)
            poller.cancel()
            status = await engine.assetStatus(for: locale)
            try? await engine.prepare()
        } catch {
            poller.cancel()
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
