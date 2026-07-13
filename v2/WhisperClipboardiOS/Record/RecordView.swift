import Core
import Foundation
import SwiftUI
import UIKit
import WhisperShared

/// The "Opnemen" tab: a big yellow record button, a live level meter and elapsed
/// timer while recording, then the transcribed result with a "Kopieer" button.
///
/// Recording flow (mirrors the mac dictation pipeline, minus the HUD/hotkey):
///   tap record → `IOSAudioEngine.start(convertingTo: 16 kHz mono)` →
///   feed each buffer into `ParakeetEngine` → tap stop → `engine.finalize()` →
///   `TextProcessor.process(clean: true)` → save to `HistoryStore` (source "mic")
///   → show result + copy.
struct RecordView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = RecordController()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                content
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(size: 20)
                }
            }
        }
        .task {
            controller.attach(app: app)
            // Dekt de koude start en terugkeer naar dit tabblad: een resultaat
            // van meer dan vijf minuten oud hoort dan al gewist te zijn.
            controller.clearResultIfExpired()
            await app.refreshModelStatus()
        }
        // Auto-wis bij elk foreground-moment (app komt terug in beeld). Er loopt
        // geen achtergrond-timer; dit event is het enige check-moment.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.clearResultIfExpired() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !app.modelStatus.isReady {
            ModelDownloadCard()
        } else {
            VStack(spacing: 32) {
                Spacer()
                statusText
                HStack(spacing: 28) {
                    if controller.isRecording {
                        // Onzichtbare tegenhanger zodat de opnameknop gecentreerd
                        // blijft terwijl de pauzeknop rechts verschijnt.
                        PauseToggleButton(isPaused: false, enabled: false) {}
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                    RecordButton(
                        isRecording: controller.isRecording,
                        isBusy: controller.isTranscribing,
                        level: controller.level
                    ) {
                        controller.toggle()
                    }
                    if controller.isRecording {
                        PauseToggleButton(
                            isPaused: controller.isPaused,
                            // Tijdens een onderbrekings-pauze hervat het systeem
                            // zelf; de knop staat dan uit.
                            enabled: !controller.pausedByInterruption
                        ) {
                            controller.togglePause()
                        }
                    }
                }
                if controller.isRecording {
                    VStack(spacing: 12) {
                        LevelBars(level: controller.isPaused ? 0 : controller.level)
                        Text(Self.formatElapsed(controller.elapsed))
                            .font(ThemeFont.ui(28, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.text)
                        if controller.isPaused {
                            Label(
                                controller.pausedByInterruption ? "Gepauzeerd (onderbreking)" : "Gepauzeerd",
                                systemImage: "pause.circle"
                            )
                            .font(ThemeFont.ui(13, weight: .medium))
                            .foregroundStyle(Theme.danger)
                        }
                    }
                }
                Spacer()
                if let result = controller.lastResult, !controller.isRecording {
                    ResultCard(text: result) {
                        UIPasteboard.general.string = result
                        controller.markCopied()
                    } copied: {
                        controller.didCopy
                    } onClear: {
                        controller.clearResult()
                    }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
        }
    }

    private var statusText: some View {
        Text(controller.statusLine)
            .font(ThemeFont.ui(15))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Level bars

/// Een cluster gele niveau-balken dat op de live RMS-`level` reageert. Poort van
/// de Mac-`LevelBars`: de balkhoogtes komen uit één scalair niveau via een
/// center-gewogen profiel (midden hoger dan de randen).
private struct LevelBars: View {
    let level: Double

    private let barCount = 7

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: height(for: index))
            }
        }
        .frame(height: 32, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(barCount - 1) / 2)
        let profile = 1.0 - distance / Double(barCount)
        let magnitude = max(0.15, level) * profile
        return CGFloat(6 + magnitude * 24)
    }
}

// MARK: - Record button

/// The record button: a yellow ring with a rounded-square core (matching the app
/// icon motif). Square shrinks into a smaller "stop" square while recording.
private struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let level: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isRecording ? Theme.danger : Theme.accent, lineWidth: 6)
                    .frame(width: 132, height: 132)
                    // Live level ripple while recording.
                    .scaleEffect(isRecording ? 1 + CGFloat(level) * 0.08 : 1)

                // Proportions match the app icon: the rounded square is ~42% of
                // the ring's diameter (not a fat fill), so button and icon read
                // as the same motif.
                RoundedRectangle(cornerRadius: isRecording ? 8 : 14, style: .continuous)
                    .fill(isRecording ? Theme.danger : Theme.accent)
                    .frame(
                        width: isRecording ? 46 : 56,
                        height: isRecording ? 46 : 56
                    )

                if isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                        .scaleEffect(1.3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
    }
}

// MARK: - Result card

private struct ResultCard: View {
    let text: String
    let onCopy: () -> Void
    let copied: () -> Bool
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Onopvallende "Wis"-knop rechtsboven: leegt het scherm en zet de
            // status terug op de ruststand. De entry blijft in de Geschiedenis.
            HStack {
                Spacer()
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wis resultaat")
            }

            ScrollView {
                Text(text)
                    .font(ThemeFont.ui(16))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)

            Button(action: onCopy) {
                Label(copied() ? "Gekopieerd" : "Kopieer", systemImage: copied() ? "checkmark" : "doc.on.doc")
                    .font(ThemeFont.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .themeCard()
    }
}
