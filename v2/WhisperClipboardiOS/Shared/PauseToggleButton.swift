import SwiftUI

/// Ronde secundaire knop naast de opnameknop: pauzeert (twee balkjes) of hervat
/// (driehoekje) de lopende opname. Gedeeld door het Opnemen-tabblad en de
/// notitie-detailweergave.
struct PauseToggleButton: View {
    @Environment(\.locale) private var locale
    let isPaused: Bool
    let enabled: Bool
    var size: CGFloat = 56
    var symbolSize: CGFloat = 18
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                Circle()
                    .strokeBorder(prominent ? Theme.accent : Theme.border, lineWidth: prominent ? 6 : 1.5)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(enabled ? (prominent ? Theme.accent : Theme.text) : Theme.textTertiary)
            }
            .frame(width: size, height: size)
            .shadow(color: prominent ? Theme.accent.opacity(0.28) : .clear, radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            isPaused
                ? L10n.string( "Hervat opname", locale: locale)
                : L10n.string( "Pauzeer opname", locale: locale)
        )
    }
}
