import Core
import SwiftUI

/// Stap 1 van de private notulist: deelnemers invoeren (naam + e-mailadres, of
/// anoniem). Pas wanneer er minstens één geldige deelnemer is, kan de opname
/// starten. Deelnemers zijn bewust per sessie — ze worden nergens bewaard.
struct MeetingSetupView: View {
    @EnvironmentObject private var app: AppModel

    /// Bewerkbare rijen; omgezet naar `MeetingParticipant` bij de start.
    @State private var rows: [Row] = [Row()]
    @State private var started = false

    struct Row: Identifiable {
        let id = UUID()
        var name = ""
        var email = ""
        var isAnonymous = false

        var participant: MeetingParticipant {
            MeetingParticipant(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: isAnonymous ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private var participants: [MeetingParticipant] { rows.map(\.participant) }

    /// Start kan zodra elke rij geldig is én er minstens één mail-ontvanger is
    /// (anders valt er niets te versturen).
    private var canStart: Bool {
        !rows.isEmpty
            && participants.allSatisfy(\.isValid)
            && !MeetingMinutesComposer.recipients(participants).isEmpty
            && app.modelStatus.isReady
    }

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            List {
                Section {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Naam", text: $row.name)
                                .font(ThemeFont.ui(16))
                            Toggle("Anoniem", isOn: $row.isAnonymous)
                                .font(ThemeFont.ui(14))
                                .tint(Theme.accent)
                            if !row.isAnonymous {
                                TextField("E-mailadres", text: $row.email)
                                    .font(ThemeFont.ui(16))
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        rows.remove(atOffsets: offsets)
                    }

                    Button {
                        rows.append(Row())
                    } label: {
                        Label("Voeg deelnemer toe", systemImage: "person.badge.plus")
                            .foregroundStyle(Theme.accentText)
                    }
                } header: {
                    Text("Deelnemers")
                } footer: {
                    Text("Iedereen met een e-mailadres ontvangt na afloop exact hetzelfde verslag. Anonieme deelnemers tellen mee als aanwezig maar krijgen geen mail. Deze lijst wordt nergens bewaard.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    EmptyView()
                } footer: {
                    Text("De opname en transcriptie gebeuren volledig lokaal op deze iPhone — geen cloud, geen externe AI-dienst. De audio wordt nooit als bestand opgeslagen en gepauzeerde stukken worden nergens vastgelegd.")
                }

                Section {
                    Button {
                        started = true
                    } label: {
                        Label("Start opname", systemImage: "record.circle")
                            .font(ThemeFont.ui(16, weight: .semibold))
                            .foregroundStyle(canStart ? Theme.accentText : Theme.textTertiary)
                    }
                    .disabled(!canStart)
                } footer: {
                    if !app.modelStatus.isReady {
                        Text("Het spraakmodel is nog niet gereed — download het eerst via het Opnemen-tabblad.")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Notulen")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $started) {
            MeetingRecordView(participants: participants)
        }
    }
}
