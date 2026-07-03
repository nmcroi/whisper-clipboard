import SwiftUI
import Translation

/// The bottom-centre live-captions overlay content.
///
/// Shows at most the last **2 final** caption lines plus **1 volatile**
/// (in-progress) line — newest emphasized (white, semibold), older lines dimmed —
/// over the same near-black HUD background. A small red "LIVE" dot + "Ondertitels"
/// label and a translate toggle sit top-left/right; a close (✕) button top-right.
///
/// ## Translation (Part B)
/// When translation is enabled, an invisible `.translationTask` hosts a live
/// `TranslationSession` for as long as the overlay is up. It drains the service's
/// `pendingTranslations` queue: each finalized foreign line is translated to Dutch
/// and swapped in, keeping the original as a smaller dimmed line above it.
struct CaptionOverlayView: View {
    @ObservedObject var service: CaptionsService
    /// Invoked when the user clicks the close button (stops the session).
    let onClose: () -> Void

    /// The Translation session configuration. Rebuilt (new `version`) whenever the
    /// toggle flips so the `.translationTask` re-attaches a fresh session.
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            captions
            if let hint = service.translationHint {
                Text(hint)
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
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
        // Quick opacity crossfade only — no layout bounce.
        .animation(.easeInOut(duration: 0.18), value: displayLines)
        .animation(.easeInOut(duration: 0.18), value: service.translationHint)
        // Live translation host: the session lives while the overlay is up. The
        // session is used only inside this closure's task (never sent to another
        // isolation domain); service reads/writes hop to the main actor.
        .translationTask(translationConfig) { @Sendable session in
            await runTranslationLoop(session: session, service: service)
        }
        .onAppear { syncTranslationConfig() }
        .onChange(of: service.translateEnabled) { _, _ in syncTranslationConfig() }
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
            translateToggle
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

    /// A small icon-toggle to flip live Dutch translation on/off from the overlay.
    private var translateToggle: some View {
        Button {
            service.translateEnabled.toggle()
        } label: {
            Image(systemName: "character.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(service.translateEnabled ? Theme.accentText : Theme.textSecondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(service.translateEnabled ? "Live vertaling naar Nederlands uitschakelen" : "Live vertaling naar Nederlands inschakelen")
    }

    // MARK: - Captions

    /// At most the last 2 final lines plus a trailing volatile line.
    private var displayLines: [CaptionLine] {
        let all = service.lines
        guard !all.isEmpty else { return [] }
        let volatile = all.last(where: { !$0.isFinal })
        let finals = all.filter { $0.isFinal }.suffix(2)
        var result = Array(finals)
        // Keep the volatile line as the last row (never reordered).
        if let volatile, !result.contains(where: { $0.id == volatile.id }) {
            result.append(volatile)
        }
        return result
    }

    @ViewBuilder
    private var captions: some View {
        let lines = displayLines
        if lines.isEmpty {
            Text("Luisteren naar systeemaudio…")
                .font(ThemeFont.ui(15))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    row(for: line, isNewest: index == lines.count - 1)
                }
            }
        }
    }

    /// One caption row. When a translation is present, the original is shown as a
    /// smaller dimmed line above the Dutch text.
    @ViewBuilder
    private func row(for line: CaptionLine, isNewest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let dutch = line.translation {
                Text(line.text)
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(dutch)
                    .font(isNewest ? ThemeFont.ui(17, weight: .semibold) : ThemeFont.ui(15))
                    .foregroundStyle(foreground(for: line, isNewest: isNewest))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line.text.isEmpty ? "…" : line.text)
                    .font(isNewest ? ThemeFont.ui(17, weight: .semibold) : ThemeFont.ui(15))
                    .foregroundStyle(foreground(for: line, isNewest: isNewest))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(line.id)
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
        // Solid, near-opaque themed surface so captions read over any content:
        // near-black in dark mode, near-white in light mode.
        ZStack {
            Theme.window.opacity(0.96)
            Rectangle().fill(.ultraThinMaterial).opacity(0.12)
        }
    }

    // MARK: - Translation driving

    /// Rebuilds the translation config when the toggle changes. `nil` tears down
    /// the session; a Dutch-target config (auto source) spins one up.
    private func syncTranslationConfig() {
        if service.translateEnabled {
            if translationConfig == nil {
                translationConfig = TranslationSession.Configuration(
                    source: nil, // auto-detect
                    target: Locale.Language(identifier: "nl")
                )
            }
        } else {
            translationConfig = nil
        }
    }

}

/// Drives translation of the service's pending queue with a live session, staying
/// entirely on the main actor so the (main-isolated) `TranslationSession` is never
/// sent across an isolation boundary. Loops until the task is cancelled (i.e. the
/// overlay/session tears down).
/// Drives translation of the service's pending queue with a live session. This is
/// a `nonisolated` free function so the non-`Sendable` ``TranslationSession`` is
/// used in a non-isolated region (never sent across an actor boundary); all
/// ``CaptionsService`` access hops to the main actor via `await`. Loops until the
/// task is cancelled (i.e. the overlay/session tears down).
nonisolated private func runTranslationLoop(
    session: TranslationSession,
    service: CaptionsService
) async {
    // Prepare assets (surfaces the system download prompt on first use).
    do {
        try await session.prepareTranslation()
    } catch {
        for pending in await service.pendingTranslations {
            await service.failTranslation(lineID: pending.id, unavailable: true)
        }
    }

    while !Task.isCancelled {
        let queue = await service.pendingTranslations
        if queue.isEmpty {
            try? await Task.sleep(nanoseconds: 120_000_000) // 0.12 s
            continue
        }
        for pending in queue {
            if Task.isCancelled { return }
            do {
                let response = try await session.translate(pending.text)
                let dutch = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if dutch.isEmpty {
                    await service.failTranslation(lineID: pending.id, unavailable: false)
                } else {
                    await service.applyTranslation(lineID: pending.id, dutch: dutch)
                }
            } catch {
                await service.failTranslation(lineID: pending.id, unavailable: true)
            }
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
