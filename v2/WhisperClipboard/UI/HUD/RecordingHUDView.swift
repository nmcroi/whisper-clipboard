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
    @ObservedObject var levelMeter: AudioLevelMeter

    /// Whether to show the latency debug line (UserDefaults `showLatencyHUD`).
    let showLatency: Bool

    /// Drives the entrance scale: starts slightly shrunk and settles to 1.0
    /// as soon as the view appears, echoing the panel's own fade/drift-in so
    /// the two read as one coordinated arrival rather than two effects.
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .animation(.easeOut(duration: 0.15), value: controller.phase)
            transcript
                .animation(.easeOut(duration: 0.15), value: controller.phase)
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
        )
        .animation(.easeOut(duration: 0.15), value: controller.phase)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
        .scaleEffect(appeared ? 1.0 : 0.97)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                appeared = true
            }
        }
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
        case .recording:
            HStack(spacing: 10) {
                PulsingDot()
                Text(Self.timeString(controller.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer()
                LevelBars(level: levelMeter.level)
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
            (
                Text(partial.finalizedText)
                    .foregroundStyle(Theme.text)
                + Text(partial.volatileText)
                    .foregroundStyle(Theme.text.opacity(0.55))
            )
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
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Stop dicteren")
    }
}

/// A small cluster of yellow audio-level bars reacting to the live RMS level.
private struct LevelBars: View {
    let level: Double

    private let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: 20, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(barCount - 1) / 2)
        let profile = 1.0 - distance / Double(barCount)
        let magnitude = max(0.15, level) * profile
        return CGFloat(4 + magnitude * 16)
    }
}
