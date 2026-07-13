import SwiftUI

/// Snackbar onderin het scherm met een boodschap en een undo-knop, in het
/// patroon van Apple Mail/Notities: na een destructieve actie een paar seconden
/// de kans om hem terug te draaien. De presentatielogica (timing, wat undo
/// betekent) blijft bij de aanroeper; dit is alleen de weergave.
struct UndoToast: View {
    let message: String
    let actionTitle: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(ThemeFont.ui(14))
                .foregroundStyle(Theme.text)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(action: onUndo) {
                Text(actionTitle)
                    .font(ThemeFont.ui(14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: Theme.Metrics.hairline)
                )
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dubbeltik om het verwijderen ongedaan te maken.")
    }
}

extension View {
    /// Toont een ``UndoToast`` als overlay onderaan deze view zolang
    /// `isPresented` waar is. Verschijnt en verdwijnt met een subtiele
    /// schuif/fade; het tijdvenster bepaalt de aanroeper zelf.
    func undoToast(
        isPresented: Bool,
        message: String,
        actionTitle: String = "Ongedaan maken",
        onUndo: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .bottom) {
            if isPresented {
                UndoToast(message: message, actionTitle: actionTitle, onUndo: onUndo)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}
