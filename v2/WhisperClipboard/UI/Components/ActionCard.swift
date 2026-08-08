import SwiftUI

/// Reusable dark action card: an SF Symbol icon over a title and subtitle.
///
/// Dark surface, 1px border, radius 12. When `enabled` and given an `action`,
/// the whole card is a button that lifts its border to yellow on hover. When
/// disabled it dims and (optionally) shows a small "komt eraan" badge.
struct ActionCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var enabled: Bool = true
    /// Optional trailing hint (e.g. the current hotkey) shown as a pill.
    var hint: String? = nil
    /// Optional badge shown when disabled (e.g. "M3").
    var badge: String? = nil
    /// When true, shows a red "active" dot in the icon row (e.g. captions running).
    var active: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button {
            action?()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(!enabled || action == nil)
        .onHover { isHovering = $0 && enabled }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(enabled ? "" : "Komt in een latere versie")
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? Theme.danger : (enabled ? Theme.accent : Theme.textTertiary))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ThemeFont.ui(14, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.text : Theme.textSecondary)
                Text(subtitle)
                    .font(ThemeFont.ui(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if active {
                Circle().fill(Theme.danger).frame(width: 7, height: 7)
            } else if let hint {
                Text(hint)
                    .font(ThemeFont.ui(10, weight: .medium).monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceHover)
                    .clipShape(Capsule())
            } else if let badge, !enabled {
                Text(badge)
                    .font(ThemeFont.ui(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .themeCard(border: isHovering ? Theme.accent.opacity(0.6) : Theme.border)
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}
