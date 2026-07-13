import Core
import SwiftUI

/// De woordenlijst op iOS: dezelfde find → replace-regels als op de Mac
/// (Instellingen ▸ Woordenlijst). Elke regel vervangt een heel woord,
/// hoofdletterongevoelig, in elke transcriptie. Bewerken gaat direct op
/// `AppModel.replacements`; persistentie en iCloud-sync zitten in de didSet
/// daarvan.
struct DictionaryiOSView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            List {
                Section {
                    if app.replacements.isEmpty {
                        emptyState
                    } else {
                        ForEach(app.replacements.indices, id: \.self) { index in
                            replacementRow(index)
                        }
                        .onDelete { offsets in
                            app.replacements.remove(atOffsets: offsets)
                        }
                    }

                    Button {
                        app.replacements.append(Replacement(find: "", replace: ""))
                    } label: {
                        Label("Voeg toe", systemImage: "plus")
                            .foregroundStyle(Theme.accentText)
                    }
                } footer: {
                    Text("Corrigeer woorden die de spraakherkenning vaak verkeerd verstaat. Elk woord links wordt overal vervangen door de tekst rechts — hele woorden, hoofdletterongevoelig. Bijvoorbeeld: ‘klot’ → ‘Claude’.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Woordenlijst")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func replacementRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            TextField(
                "Verstaan als…",
                text: Binding(
                    get: { app.replacements[safe: index]?.find ?? "" },
                    set: { app.replacements[safe: index]?.find = $0 }
                )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            TextField(
                "Vervang door…",
                text: Binding(
                    get: { app.replacements[safe: index]?.replace ?? "" },
                    set: { app.replacements[safe: index]?.replace = $0 }
                )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .font(ThemeFont.ui(16))
        .foregroundStyle(Theme.text)
    }

    private var emptyState: some View {
        Text("Nog geen vervangingen")
            .font(ThemeFont.ui(14))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Safe-subscript voor de indexed bindings hierboven: schrijven via een
/// verouderde index (bijv. vlak na een verwijdering) is een no-op in plaats
/// van een crash. Zelfde helper als in de Mac-DictionarySettingsView.
private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}
