import SwiftUI

/// Ronde secundaire knop naast de opnameknop: pauzeert (twee balkjes) of hervat
/// (driehoekje) de lopende opname. Gedeeld door het Opnemen-tabblad en de
/// notitie-detailweergave.
struct PauseToggleButton: View {
    let isPaused: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                Circle()
                    .strokeBorder(Theme.border, lineWidth: 1.5)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.text : Theme.textTertiary)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isPaused ? "Hervat opname" : "Pauzeer opname")
    }
}
