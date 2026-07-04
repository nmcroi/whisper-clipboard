import Core
import SwiftUI
import WhisperShared

/// De AI-samenvat-sheet voor een hele notitie (i3): dezelfde modus-chips en
/// vrije-prompt als bij een transcript, maar dan op de samengevoegde tekst van
/// alle opnames in de notitie. Het resultaat streamt live in de sheet met een
/// kopieerknop. Resultaten worden bewust niet bewaard (v1) — zie
/// `NoteDetailiOSView.summarizeEntry()`.
struct NoteSummarizeSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let entry: TranscriptEntry
    let modes: ModesService

    /// Lokale instellingen-sheet zodat een key ook vanuit hier gezet kan worden
    /// wanneer er nog geen is.
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Deze notitie bevat nog geen tekst om samen te vatten.")
                                .font(ThemeFont.ui(15))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            AIRunnerView(
                                entry: entry,
                                modes: modes,
                                showStoredResults: false
                            ) {
                                showSettings = true
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Samenvatten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") { dismiss() }
                        .foregroundStyle(Theme.accentText)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .environmentObject(app)
                    .preferredColorScheme(app.appearance.preferredColorScheme)
            }
        }
    }
}
