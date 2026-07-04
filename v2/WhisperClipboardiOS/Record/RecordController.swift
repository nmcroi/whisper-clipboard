import AVFoundation
import Core
import Foundation
import SwiftUI
import WhisperShared

/// Drives one record → transcribe → save cycle on the Record tab.
///
/// Owns the ``IOSAudioEngine``, feeds captured buffers into the shared
/// ``ParakeetEngine``, and on stop runs finalize → `TextProcessor.process` →
/// `HistoryStore.add`. Publishes the state the view renders (recording flag,
/// elapsed time, level, transcribing spinner, last result).
@MainActor
final class RecordController: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var lastResult: String?
    @Published private(set) var didCopy = false
    @Published private(set) var statusLine = "Tik om op te nemen"

    private var app: AppModel?
    private var audio: IOSAudioEngine?
    private var feedTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var levelCancellable: AnyObject?
    private let liveActivity = RecordingLiveActivityController()

    func attach(app: AppModel) {
        self.app = app
    }

    // MARK: - Toggle

    func toggle() {
        if isRecording {
            Task { await stopAndTranscribe() }
        } else {
            Task { await start() }
        }
    }

    // MARK: - Start

    private func start() async {
        guard let app else { return }
        didCopy = false
        lastResult = nil
        statusLine = "Bezig met opnemen…"

        let engine = app.engine
        guard let format = await engine.bestAudioFormat() else {
            fail("Audioformaat niet beschikbaar.")
            return
        }

        let audio = IOSAudioEngine()
        audio.onInterruption = { [weak self] in
            Task { await self?.stopAndTranscribe() }
        }
        audio.onPause = { [weak self] in
            guard let self else { return }
            self.isPaused = true
            self.statusLine = "Gepauzeerd (onderbreking)"
            self.liveActivity.setPaused(true)
        }
        audio.onResume = { [weak self] in
            guard let self else { return }
            self.isPaused = false
            self.statusLine = "Bezig met opnemen…"
            self.liveActivity.setPaused(false)
        }
        self.audio = audio

        do {
            try await engine.startStreaming(locale: Locale(identifier: "nl_NL"))
            let stream = try await audio.start(convertingTo: format)
            isRecording = true
            isPaused = false
            liveActivity.start()
            startTicking(audio: audio)
            // Pump captured buffers into the engine off the record loop.
            feedTask = Task { [weak self] in
                for await box in stream {
                    await engine.feed(box)
                    _ = self // keep alive
                }
            }
        } catch {
            await engine.cancel()
            self.audio = nil
            liveActivity.end()
            fail(error.localizedDescription)
        }
    }

    private func startTicking(audio: IOSAudioEngine) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self, self.isRecording else { return }
                    self.elapsed = audio.elapsed
                    // Tijdens pauze geen levels doorsturen (blijft op 0 staan).
                    let live = audio.isPaused ? 0 : audio.levelMeter.level
                    self.level = live
                    self.liveActivity.push(level: live)
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    // MARK: - Stop

    private func stopAndTranscribe() async {
        guard isRecording, let app else { return }
        isRecording = false
        isPaused = false
        tickTask?.cancel()
        tickTask = nil
        level = 0
        liveActivity.end()

        audio?.stop()
        // Let the last in-flight buffers drain into the engine.
        feedTask?.cancel()
        feedTask = nil
        audio = nil

        isTranscribing = true
        statusLine = "Bezig met transcriberen…"

        do {
            let result = try await app.engine.finalize()
            isTranscribing = false
            let processed = TextProcessor.process(
                result.text,
                replacements: [],
                clean: true,
                language: "nl"
            )
            guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastResult = nil
                statusLine = "Geen spraak herkend. Tik om opnieuw op te nemen."
                return
            }
            lastResult = processed
            statusLine = "Klaar. Tik om opnieuw op te nemen."
            save(processed, segments: result.segments, duration: elapsed)
        } catch {
            isTranscribing = false
            fail(error.localizedDescription)
        }
    }

    // MARK: - Save

    private func save(_ text: String, segments: [TranscriptSegment], duration: Double) {
        guard let history = app?.history else { return }
        let entry = TranscriptEntry(
            id: UUID().uuidString,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            name: "",
            pinned: false,
            language: "nl",
            model: "parakeet-tdt-0.6b-v3",
            source: "mic",
            duration: duration,
            segments: segments
        )
        try? history.add(entry)
    }

    func markCopied() {
        didCopy = true
    }

    // MARK: - Failure

    private func fail(_ message: String) {
        isRecording = false
        isPaused = false
        isTranscribing = false
        tickTask?.cancel()
        tickTask = nil
        liveActivity.end()
        app?.errorMessage = message
        statusLine = "Er ging iets mis. Tik om opnieuw te proberen."
    }
}
