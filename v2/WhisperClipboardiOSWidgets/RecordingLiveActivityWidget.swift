import ActivityKit
import SwiftUI
import WidgetKit

/// De widget-bundle van de iOS-app. Bevat (voorlopig alleen) de Live Activity
/// voor een lopende opname.
@main
struct WhisperClipboardiOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

// MARK: - Kleuren

/// Het thema van de app is donker/strak: zwart-geel-rood-wit. De widget-extensie
/// kan de app-assets/-fonts niet gebruiken, dus we gebruiken kale SwiftUI-kleuren
/// die byte-identiek zijn aan `ThemeiOS`.
private enum WidgetTheme {
    /// Geel accent (level-balken, ring) — FFD60A.
    static let accent = Color(red: 1.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0)
    /// Rood — opname-stip / danger — FF453A.
    static let danger = Color(red: 1.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
    /// Bijna-wit — tekst — F5F5F7.
    static let text = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
    /// Bijna-zwart — achtergrond — 0E0E10.
    static let background = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x10 / 255.0)
}

// MARK: - Widget

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // Lock-screen / banner-presentatie.
            LockScreenView(state: context.state)
                .activityBackgroundTint(WidgetTheme.background)
                .activitySystemActionForegroundColor(WidgetTheme.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingDot(isPaused: context.state.isPaused)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(WidgetTheme.text)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.isPaused ? "Gepauzeerd" : "Opname loopt")
                        .font(.caption)
                        .foregroundStyle(WidgetTheme.text.opacity(0.85))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EqualizerBars(levels: context.state.levels, height: 26)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
            } compactLeading: {
                MiniBars(levels: context.state.levels)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(WidgetTheme.text)
                    .frame(maxWidth: 54)
            } minimal: {
                RecordingDot(isPaused: context.state.isPaused)
            }
            .keylineTint(WidgetTheme.accent)
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            RecordingDot(isPaused: state.isPaused)
            VStack(alignment: .leading, spacing: 4) {
                Text("Whisper Clipboard")
                    .font(.headline)
                    .foregroundStyle(WidgetTheme.text)
                Text(state.isPaused ? "Gepauzeerd (onderbreking)" : "Opname loopt")
                    .font(.caption)
                    .foregroundStyle(WidgetTheme.text.opacity(0.75))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                TimerText(state: state)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundStyle(WidgetTheme.text)
                EqualizerBars(levels: state.levels, height: 20)
            }
        }
        .padding(16)
    }
}

// MARK: - Bouwstenen

/// De pulserende rode opname-stip (dimt weg bij pauze).
private struct RecordingDot: View {
    let isPaused: Bool

    var body: some View {
        Circle()
            .fill(isPaused ? WidgetTheme.danger.opacity(0.4) : WidgetTheme.danger)
            .frame(width: 12, height: 12)
    }
}

/// Native tikkende (mee-tellende) tijd sinds de opname begon. Bij pauze bevriezen
/// we op een statische mm:ss zodat de teller niet doorloopt.
private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(Self.elapsedString(since: state.startedAt))
        } else {
            Text(state.startedAt, style: .timer)
        }
    }

    private static func elapsedString(since date: Date) -> String {
        let total = Int(max(0, Date().timeIntervalSince(date)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Equalizer met gele balken, aangedreven door de `levels`-array zodat de balken
/// onderling verschillen. Poort van de Mac-`LevelBars`, maar per-balk gevoed.
private struct EqualizerBars: View {
    let levels: [Double]
    var height: CGFloat = 24

    private var barCount: Int { max(levels.count, 5) }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(WidgetTheme.accent)
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: height, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = index < levels.count ? levels[index] : 0
        let magnitude = max(0.12, min(1, level))
        return 4 + magnitude * (height - 6)
    }
}

/// Drie mini-balkjes voor de compacte Dynamic Island (compactLeading).
private struct MiniBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(WidgetTheme.accent)
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .frame(height: 16, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    private func height(for index: Int) -> CGFloat {
        // Kies drie representatieve waarden uit de reeks.
        guard !levels.isEmpty else { return 5 }
        let pick = levels[(index * levels.count / 3) % levels.count]
        return 5 + CGFloat(max(0.12, min(1, pick))) * 9
    }
}
