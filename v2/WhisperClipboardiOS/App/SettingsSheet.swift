import Core
import SwiftUI

/// Placeholder settings sheet for i0+i1: just the "Thema" picker. Later rounds
/// add replacements, retention, filler removal and iCloud sync.
struct SettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.window.ignoresSafeArea()
                Form {
                    Section("Thema") {
                        Picker("Weergave", selection: $app.appearance) {
                            ForEach(AppSettings.AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Theme.surface)

                    Section {
                        LabeledContent("Model", value: "Parakeet TDT 0.6b v3")
                        LabeledContent("Taal", value: "Nederlands")
                    } header: {
                        Text("Over")
                    } footer: {
                        Text("Alle transcriptie gebeurt lokaal op je iPhone. Er verlaat geen audio je toestel.")
                    }
                    .listRowBackground(Theme.surface)
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.text)
            }
            .navigationTitle("Instellingen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gereed") { dismiss() }
                        .foregroundStyle(Theme.accentText)
                }
            }
        }
    }
}
