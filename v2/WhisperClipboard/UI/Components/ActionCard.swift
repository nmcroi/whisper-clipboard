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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(enabled ? Theme.accent : Theme.textTertiary)
                Spacer()
                if let badge, !enabled {
                    Text(badge)
                        .font(ThemeFont.ui(10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceHover)
                        .clipShape(Capsule())
                }
            }

            Text(title)
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.textSecondary)

            Text(subtitle)
                .font(ThemeFont.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let hint {
                Text(hint)
                    .font(ThemeFont.ui(11, weight: .medium).monospaced())
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceHover)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(16)
        .themeCard(border: isHovering ? Theme.accent.opacity(0.6) : Theme.border)
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}
