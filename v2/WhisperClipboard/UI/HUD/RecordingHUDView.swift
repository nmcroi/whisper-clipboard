import SwiftUI

/// NightStory-styled floating HUD content shown while dictating.
///
/// Dark marine translucent background, terra/white accents. Shows a pulsing
/// recording dot + elapsed time + live level bars while recording, the live
/// transcript (finalized white, volatile 60% opacity) while streaming, and a
/// brief "✓ Op klembord" confirmation on completion.
struct RecordingHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var levelMeter: AudioLevelMeter

    /// Whether to show the latency debug line (UserDefaults `showLatencyHUD`).
    let showLatency: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcript
            if showLatency {
                Text(controller.lastMetrics.debugLine)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 360, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(NightStory.terra.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)
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
                    .foregroundStyle(.white)
                Spacer()
                LevelBars(level: levelMeter.level)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(NightStory.warm)
                Text("Transcriberen…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }
        case .finished, .idle:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NightStory.warm)
                Text("Op klembord")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
                    .foregroundStyle(.white)
                + Text(partial.volatileText)
                    .foregroundStyle(.white.opacity(0.6))
            )
            .font(.system(size: 13, weight: .regular))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if controller.phase == .recording {
            Text("Spreek nu…")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var background: some View {
        ZStack {
            NightStory.marine.opacity(0.82)
            Rectangle().fill(.ultraThinMaterial).opacity(0.25)
        }
    }

    // MARK: - Helpers

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A terra recording dot that pulses while recording.
private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(NightStory.terra)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 1.25 : 0.85)
            .opacity(pulsing ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// A small cluster of audio-level bars reacting to the live RMS level.
private struct LevelBars: View {
    let level: Double

    private let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(NightStory.warm)
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: 20, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // Center bars taller; scale by level with a small floor.
        let distance = abs(Double(index) - Double(barCount - 1) / 2)
        let profile = 1.0 - distance / Double(barCount)
        let magnitude = max(0.15, level) * profile
        return CGFloat(4 + magnitude * 16)
    }
}
