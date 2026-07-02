import AVFoundation
import Core
import Foundation
import Speech

/// Errors from the Apple Speech backend.
enum AppleSpeechEngineError: LocalizedError {
    case localeUnsupported(String)
    case modelNotInstalled
    case notStreaming

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let id):
            return "De taal ‘\(id)’ wordt niet ondersteund voor spraakherkenning."
        case .modelNotInstalled:
            return "Het spraakmodel is nog niet gedownload."
        case .notStreaming:
            return "Er loopt geen opnamesessie."
        }
    }
}

/// `SpeechAnalyzer` + `SpeechTranscriber` streaming backend for macOS 26.
///
/// An actor so the analyzer, transcriber, input continuation, and result
/// accumulator are mutated on a single isolation domain. The public `partials`
/// stream is created up front; a fresh internal continuation is installed for
/// each streaming session.
actor AppleSpeechEngine: TranscriptionEngine {

    // MARK: - Partials stream

    nonisolated let partials: AsyncStream<StreamingPartial>
    private let partialsContinuation: AsyncStream<StreamingPartial>.Continuation

    // MARK: - Session state

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var accumulator = PartialAccumulator()
    private var preparedLocale: Locale?

    init() {
        let (stream, continuation) = AsyncStream<StreamingPartial>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        partials = stream
        partialsContinuation = continuation
    }

    // MARK: - Supported languages

    /// The ISO language codes (e.g. "en", "nl") that `SpeechTranscriber`
    /// advertises support for on this machine. Used by ``EngineSelector`` to
    /// decide whether Apple Speech is viable for the configured language.
    ///
    /// Note: this reflects the framework's *advertised* locale list; whether the
    /// on-device asset is actually installable is decided separately by
    /// ``assetStatus(for:)`` via `AssetInventory.status`.
    static func supportedLanguageCodes() async -> Set<String> {
        let locales = await SpeechTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier })
    }

    // MARK: - Preparation

    func prepare() async throws {
        let locale = Locale(identifier: "nl-NL")
        let status = await assetStatus(for: locale)
        switch status {
        case .installed:
            try await prewarm(locale: locale)
        case .needsDownload, .downloading:
            // Leave the download to the UI-driven flow; nothing to pre-warm yet.
            break
        case .unsupported:
            throw AppleSpeechEngineError.localeUnsupported(locale.identifier)
        case .unknown:
            break
        }
    }

    /// Constructs (and discards) an analyzer once so the model is resident.
    private func prewarm(locale: Locale) async throws {
        let resolved = Self.canonical(locale)
        let transcriber = Self.makeTranscriber(locale: resolved)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        preparedLocale = resolved
        // Release the pre-warm analyzer; the real session builds its own.
        await analyzer.cancelAndFinishNow()
    }

    // MARK: - Asset management

    /// Maps `AssetInventory.status(forModules:)` — the authoritative source —
    /// onto ``ModelAssetStatus``. Note: `SpeechTranscriber.supportedLocale(equivalentTo:)`
    /// over-reports (it echoes back a canonicalized locale even for unsupported
    /// languages), so we rely on `AssetInventory.status` for the real answer.
    func assetStatus(for locale: Locale) async -> ModelAssetStatus {
        let transcriber = Self.makeTranscriber(locale: Self.canonical(locale))
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return .installed
        case .supported:
            return .needsDownload(progress: 0)
        case .downloading:
            return .downloading(progress: 0)
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }

    func downloadAssets(for locale: Locale) async throws {
        let resolved = Self.canonical(locale)
        guard await assetStatus(for: resolved) != .unsupported else {
            throw AppleSpeechEngineError.localeUnsupported(locale.identifier)
        }
        // Reserve the locale so the model can be allocated on-device.
        _ = try? await AssetInventory.reserve(locale: resolved)

        let transcriber = Self.makeTranscriber(locale: resolved)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // Nothing to install — already present.
            return
        }
        try await request.downloadAndInstall()
    }

    func bestAudioFormat() async -> AVAudioFormat? {
        let locale = preparedLocale ?? Locale(identifier: "nl-NL")
        let transcriber = Self.makeTranscriber(locale: Self.canonical(locale))
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    // MARK: - Streaming

    func startStreaming(locale: Locale) async throws {
        let resolved = Self.canonical(locale)
        let status = await assetStatus(for: resolved)
        guard status != .unsupported else {
            throw AppleSpeechEngineError.localeUnsupported(locale.identifier)
        }
        guard status.isReady else {
            throw AppleSpeechEngineError.modelNotInstalled
        }

        accumulator = PartialAccumulator()

        let transcriber = Self.makeTranscriber(locale: resolved)
        self.transcriber = transcriber

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Consume transcriber results, splitting volatile vs final.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeResults(from: transcriber)
        }

        try await analyzer.start(inputSequence: inputStream)
    }

    private func consumeResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    let (start, end) = Self.timeRange(of: result)
                    accumulator.appendFinal(text: text, start: start, end: end)
                } else {
                    accumulator.setVolatile(text: text)
                }
                partialsContinuation.yield(accumulator.partial)
            }
        } catch {
            // Stream ended with an error mid-session: keep whatever we accumulated.
        }
    }

    func feed(_ buffer: AudioBufferBox) async {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer.buffer))
    }

    func finalize() async throws -> TranscriptionResult {
        guard let analyzer else { throw AppleSpeechEngineError.notStreaming }

        // Signal end of input, then drain and finalize.
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Even on a finalize error, keep the accumulated transcript.
        }

        // Let the results task drain any final results the finalize produced.
        await resultsTask?.value

        let result = accumulator.result
        teardownSession()
        return result
    }

    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        teardownSession()
    }

    func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionResult {
        // M3: file transcription. Stubbed for M1.
        _ = url
        _ = locale
        return .empty
    }

    private func teardownSession() {
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
    }

    // MARK: - Helpers

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Normalizes a requested locale (e.g. "nl", "nl-NL") to the region-qualified
    /// identifier the Speech framework expects (e.g. "nl_NL"). Falls back to the
    /// language code alone when no region is present. Supportability is decided
    /// separately by `AssetInventory.status`.
    private static func canonical(_ locale: Locale) -> Locale {
        let language = locale.language.languageCode?.identifier ?? locale.identifier
        if let region = locale.region?.identifier {
            return Locale(identifier: "\(language)_\(region)")
        }
        // Prefer the framework's own equivalence resolution to attach a region.
        return Locale(identifier: locale.identifier.replacingOccurrences(of: "-", with: "_"))
    }

    /// Extracts a start/end time (seconds) from a result's audio time range.
    private static func timeRange(of result: SpeechTranscriber.Result) -> (Double, Double) {
        let range = result.range
        let start = range.start.seconds
        let end = range.end.seconds
        let safeStart = start.isFinite ? start : 0
        let safeEnd = end.isFinite ? end : safeStart
        return (safeStart, safeEnd)
    }
}
