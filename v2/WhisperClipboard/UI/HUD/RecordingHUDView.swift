import AppKit
import SwiftUI

/// Dark floating HUD content shown while dictating.
///
/// Near-black translucent panel, white text, a red pulsing record dot and
/// yellow level bars while recording; live transcript (finalized white,
/// volatile 55% opacity) while streaming; a brief yellow "Op klembord ✓"
/// confirmation on completion.
struct RecordingHUDView: View {
    @ObservedObject var controller: DictationController
    /// Bewust géén `@ObservedObject`: de meter publiceert per audiobuffer, en op
    /// dit niveau zou elke publicatie de hele HUD (achtergrond, schaduw,
    /// transcript) opnieuw laten renderen. Alleen ``LevelBars`` luistert mee, en
    /// dat bestaat uitsluitend tijdens het opnemen.
    let levelMeter: AudioLevelMeter

    /// Whether to show the latency debug line (UserDefaults `showLatencyHUD`).
    let showLatency: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcript
            // Detailed three-part breakdown stays behind the debug flag, and
            // only once a run has completed (so it doesn't clutter recording).
            if showLatency, controller.phase == .finished || controller.phase == .idle {
                Text(controller.lastMetrics.debugLine)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 360, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
                // Alleen de randkleur vloeit over. Tekst en knoppen wisselen
                // direct mee met de gepubliceerde fase: een cross-fade liet
                // "Aan het transcriberen…" na afloop nog even staan.
                .animation(.easeOut(duration: 0.12), value: controller.phase)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }

    private var borderColor: Color {
        switch controller.phase {
        case .recording: return Theme.danger.opacity(0.5)
        default: return Theme.border
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        switch controller.phase {
        case .preparing:
            // Geen rode stip en geen teller: er wordt nog niets opgenomen
            // (bevinding 2026-08-03).
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text("Even klaarzetten…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        case .recording:
            HStack(spacing: 10) {
                PulsingDot()
                Text(Self.timeString(controller.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer()
                LevelBars(meter: levelMeter)
                PauseResumeButton(isPaused: false) { controller.pauseRecording() }
                StopButton { controller.stop() }
            }
        case .paused:
            HStack(spacing: 10) {
                // Statisch, gedimd puntje: opname staat stil, niets wordt gevangen.
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 10, height: 10)
                Text(Self.timeString(controller.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text("Gepauzeerd")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                PauseResumeButton(isPaused: true) { controller.resumeRecording() }
                StopButton { controller.stop() }
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text("Aan het transcriberen…")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text.opacity(0.9))
                Spacer()
            }
        case .finished, .idle:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentText)
                Text(controller.lastInsertionOutcome == .inserted ? "Ingevoegd" : "Op klembord")
                    .font(ThemeFont.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                // Celebrate the speed: the stop→clipboard figure in Dutch.
                if let seconds = controller.lastMetrics.dutchClipboardSeconds {
                    Text("· \(seconds)")
                        .font(ThemeFont.ui(13, weight: .medium).monospaced())
                        .foregroundStyle(Theme.accentText)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let partial = controller.livePartial
        if !partial.displayText.isEmpty {
            Text("\(Text(partial.finalizedText).foregroundStyle(Theme.text))\(Text(partial.volatileText).foregroundStyle(Theme.text.opacity(0.55)))")
            .font(ThemeFont.ui(13))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if controller.phase == .recording {
            Text("Spreek nu…")
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var background: some View {
        // Solid, near-opaque themed surface so the HUD reads over any content:
        // near-black in dark mode (Niels' signature look), near-white in light
        // mode, each with a whisper of translucency.
        ZStack {
            Theme.window.opacity(0.96)
            Rectangle().fill(.ultraThinMaterial).opacity(0.12)
        }
    }

    // MARK: - Helpers

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Cursor

/// Toont het handje boven een HUD-knop en houdt de cursorstack in balans.
///
/// `NSCursor.push()` moet exact één `pop()` krijgen. De HUD verdwijnt echter
/// vaak onder de muis vandaan (fase wisselt, paneel gaat weg) zonder dat er nog
/// een hover-exit komt; dan bleef het handje hangen over het hele scherm. Deze
/// modifier onthoudt of hij zelf gepusht heeft en popt óók bij `onDisappear`,
/// nooit vaker dan één keer.
private struct PointingHandCursor: ViewModifier {
    @Binding var hovering: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                setPushed(isHovering)
            }
            // Vangnet voor de hover-exit die nooit komt.
            .onDisappear { setPushed(false) }
    }

    @MainActor
    private func setPushed(_ shouldPush: Bool) {
        guard shouldPush != pushed else { return }
        pushed = shouldPush
        if shouldPush {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}

private extension View {
    func pointingHandCursor(hovering: Binding<Bool>) -> some View {
        modifier(PointingHandCursor(hovering: hovering))
    }
}

/// A red recording dot that pulses while recording.
private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 1.25 : 0.85)
            .opacity(pulsing ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// Pauze/hervat-knop naast de stopknop: zelfde ronde ringstijl, met twee
/// pauzebalkjes (opname loopt) of een driehoekje (gepauzeerd — hervatten).
private struct PauseResumeButton: View {
    let isPaused: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.accent, lineWidth: 1.6)
                    .background(Circle().fill(hovering ? Theme.accent.opacity(0.12) : .clear))
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointingHandCursor(hovering: $hovering)
        .help(isPaused ? "Hervat opname" : "Pauzeer opname")
    }
}

/// A small round stop button shown while recording. Echoes the app icon's
/// motif: a yellow ring with a centered yellow rounded square.
private struct StopButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Theme.accent, lineWidth: 1.6)
                    .background(Circle().fill(hovering ? Theme.accent.opacity(0.12) : .clear))
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointingHandCursor(hovering: $hovering)
        .help("Stop dicteren")
    }
}

/// A small cluster of yellow audio-level bars reacting to the live RMS level.
///
/// Luistert zélf naar de meter, zodat het hertekenen per audiobuffer beperkt
/// blijft tot deze vijf balkjes en niet de hele HUD raakt.
private struct LevelBars: View {
    @ObservedObject var meter: AudioLevelMeter

    private let barCount = 5

    var body: some View {
        let level = meter.level
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: height(for: index, level: level))
            }
        }
        .frame(height: 20, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func height(for index: Int, level: Double) -> CGFloat {
        let distance = abs(Double(index) - Double(barCount - 1) / 2)
        let profile = 1.0 - distance / Double(barCount)
        let magnitude = max(0.15, level) * profile
        return CGFloat(4 + magnitude * 16)
    }
}
