import Core
import SwiftUI

/// The "Woordenlijst" settings tab: a personal dictionary of find → replace
/// rules. Each rule replaces a whole word (case-insensitive) with a literal
/// replacement everywhere a transcript is produced — dictation, file import and
/// live captions. Bound directly to `environment.settings.replacements`, which
/// `SettingsStore` persists automatically.
struct DictionarySettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider().overlay(Theme.border)
                listSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            (
                Text("Woordenlijst")
                    .foregroundStyle(Theme.text)
                + Text(".")
                    .foregroundStyle(Theme.accent)
            )
            .font(ThemeFont.ui(18, weight: .bold))

            Text("Corrigeer woorden die de spraakherkenning vaak verkeerd verstaat. Elk woord links wordt overal vervangen door de tekst rechts — hele woorden, hoofdletterongevoelig.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vervangingen")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    addRow()
                } label: {
                    Label("Voeg toe", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
            }

            if environment.settings.replacements.isEmpty {
                emptyState
            } else {
                columnHeader
                VStack(spacing: 0) {
                    ForEach(environment.settings.replacements.indices, id: \.self) { index in
                        replacementRow(index)
                        if index < environment.settings.replacements.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .themeCard()
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Verstaat")
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24)
            Text("Vervang door")
                .frame(maxWidth: .infinity, alignment: .leading)
            // Spacer matching the delete button's width so the columns line up.
            Color.clear.frame(width: 24)
        }
        .font(ThemeFont.ui(10, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
    }

    private func replacementRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            field(
                placeholder: "klot",
                text: Binding(
                    get: { environment.settings.replacements[safe: index]?.find ?? "" },
                    set: { environment.settings.replacements[safe: index]?.find = $0 }
                )
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24)
            field(
                placeholder: "Claude",
                text: Binding(
                    get: { environment.settings.replacements[safe: index]?.replace ?? "" },
                    set: { environment.settings.replacements[safe: index]?.replace = $0 }
                )
            )
            Button {
                removeRow(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24)
            .help("Verwijder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func field(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(ThemeFont.ui(13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed")
                    .foregroundStyle(Theme.textTertiary)
                Text("Nog geen vervangingen")
                    .font(ThemeFont.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Voeg een regel toe om woorden automatisch te corrigeren. Bijvoorbeeld: laat de spraakherkenning ‘klot’ overal vervangen door ‘Claude’, of ‘G-A-X’ door ‘GHX’.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    // MARK: - Mutations

    private func addRow() {
        environment.settings.replacements.append(Replacement(find: "", replace: ""))
    }

    private func removeRow(_ index: Int) {
        guard environment.settings.replacements.indices.contains(index) else { return }
        environment.settings.replacements.remove(at: index)
    }
}

/// Safe-subscript helper for the indexed bindings above: writing through a stale
/// index (e.g. right after a delete) is a no-op rather than a crash.
private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}

#Preview {
    DictionarySettingsView()
        .environmentObject(AppEnvironment())
        .frame(width: 520, height: 460)
        .preferredColorScheme(.dark)
}
