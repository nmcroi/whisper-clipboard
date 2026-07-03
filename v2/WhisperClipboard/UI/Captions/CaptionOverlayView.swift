import SwiftUI

/// The bottom-centre live-captions overlay content.
///
/// Shows the last ~3 caption lines — newest emphasized (white, semibold), older
/// lines dimmed — over the same near-black HUD background. A small red "LIVE"
/// dot + "Ondertitels" label sit top-left, a close (✕) button top-right.
struct CaptionOverlayView: View {
    @ObservedObject var service: CaptionsService
    /// Invoked when the user clicks the close button (stops the session).
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            captions
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
        .animation(.easeOut(duration: 0.25), value: service.lines)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            LiveDot()
            Text("Ondertitels")
                .font(ThemeFont.ui(11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ondertitels stoppen")
        }
    }

    // MARK: - Captions

    @ViewBuilder
    private var captions: some View {
        let lines = service.lines
        if lines.isEmpty {
            Text("Luisteren naar systeemaudio…")
                .font(ThemeFont.ui(15))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let isNewest = index == lines.count - 1
                    Text(line.text.isEmpty ? "…" : line.text)
                        // In-progress (volatile) lines render dimmed at 0.55 opacity
                        // like the dictation HUD's live text; finalized lines are
                        // full white. The newest final line stays emphasized.
                        .font(isNewest ? ThemeFont.ui(17, weight: .semibold) : ThemeFont.ui(15))
                        .foregroundStyle(foreground(for: line, isNewest: isNewest))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    /// The colour for a caption line: volatile lines are dimmed (0.55), a
    /// finalized newest line is full white, older finalized lines are softened.
    private func foreground(for line: CaptionLine, isNewest: Bool) -> Color {
        if !line.isFinal {
            return Theme.text.opacity(0.55)
        }
        return isNewest ? Theme.text : Theme.textSecondary.opacity(0.7)
    }

    private var background: some View {
        ZStack {
            Color.black.opacity(0.94)
            Rectangle().fill(.ultraThinMaterial).opacity(0.12)
        }
    }
}

/// A red pulsing "live" dot.
private struct LiveDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.2 : 0.85)
            .opacity(pulsing ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
