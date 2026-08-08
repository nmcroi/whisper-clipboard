import Core
import SwiftUI

/// Stap 1 van de private notulist: e-mailontvangers invoeren. Ontvangers zijn
/// optioneel, zodat de Notulist ook volledig lokaal en zonder e-mail kan worden
/// gebruikt. Een lege rij wordt genegeerd; een deels ingevulde rij moet geldig
/// zijn voordat de opname kan starten.
struct MeetingSetupView: View {
    @EnvironmentObject private var app: AppModel

    /// Bewerkbare rijen; omgezet naar `MeetingParticipant` bij de start.
    @State private var rows: [Row] = [Row()]
    @State private var started = false
    @State private var seededOwnContact = false
    @State private var showPrivacyInfo = false
    @State private var makeAIMinutes = false

    struct Row: Identifiable {
        let id = UUID()
        var name = ""
        var email = ""
        var saveContact = false

        func participant(defaultName: String) -> MeetingParticipant? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedName.isEmpty || !trimmedEmail.isEmpty else { return nil }

            return MeetingParticipant(
                name: trimmedName.isEmpty ? defaultName : trimmedName,
                email: trimmedEmail
            )
        }
    }

    private var enteredParticipants: [MeetingParticipant] {
        let fallback = L10n.string( "Deelnemer", locale: app.interfaceLanguage.locale)
        return rows.compactMap { $0.participant(defaultName: fallback) }
    }
    private var sessionParticipants: [MeetingParticipant] { enteredParticipants }

    /// Start kan ook zonder deelnemers: dan nemen we lokaal op als "Ik". Alleen
    /// ingevulde rijen moeten geldig zijn; lege rijen worden genegeerd.
    private var canStart: Bool {
        enteredParticipants.allSatisfy(\.isValid)
            && app.modelStatus.isReady
    }

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            VStack(spacing: 0) {
                meetingPageHeader
                List {
                    Section {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Naam", text: $row.name)
                                .font(ThemeFont.ui(16))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(Theme.surfaceHover)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1)
                                }
                            TextField("E-mailadres", text: $row.email)
                                .font(ThemeFont.ui(16))
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(Theme.surfaceHover)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1)
                                }
                            if !isStoredContact(row) {
                                Toggle(isOn: $row.saveContact) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Bewaren")
                                            .font(ThemeFont.ui(14))
                                        if app.showHelpTips {
                                            Text("Bewaar deze naam en dit e-mailadres voor volgende vergaderingen.")
                                                .font(ThemeFont.ui(12))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                .tint(Theme.accent)
                                .disabled(!(row.participant(
                                    defaultName: L10n.string( "Deelnemer", locale: app.interfaceLanguage.locale)
                                )?.isValid ?? false))
                            }
                        }
                        .padding(.trailing, 46)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                removeRow(id: row.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(
                                format: L10n.string( "Verwijder %@ uit deze vergadering", locale: app.interfaceLanguage.locale),
                                locale: app.interfaceLanguage.locale,
                                row.name.isEmpty
                                    ? L10n.string( "deelnemer", locale: app.interfaceLanguage.locale)
                                    : row.name
                            ))
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        rows.remove(atOffsets: offsets)
                    }

                    Button {
                        rows.append(Row())
                    } label: {
                        Label("Nieuwe deelnemer", systemImage: "person.badge.plus")
                            .foregroundStyle(Theme.accentText)
                    }

                    if !app.meetingContacts.isEmpty {
                        Menu {
                            ForEach(app.meetingContacts.filter(\.isValid)) { contact in
                                Button(contact.name) { add(contact) }
                            }
                        } label: {
                            Label("Kies vaste deelnemer", systemImage: "person.crop.circle.badge.checkmark")
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                    } header: {
                        Text("Deelnemers")
                    } footer: {
                        if app.showHelpTips {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Je mag dit leeg laten om alleen lokaal te transcriberen. Iedere ingevulde deelnemer is een e-mailontvanger en ontvangt na afloop exact hetzelfde verslag. Vaste deelnemers beheer je in Instellingen.")
                                if app.allowMeetingAI && makeAIMinutes {
                                    Text(String(
                                        format: L10n.string( "De opname en transcriptie gebeuren lokaal op deze iPhone. Alleen de afgeronde transcripttekst gaat naar %@; audio wordt nooit verstuurd en wordt na lokale transcriptie verwijderd. Gepauzeerde stukken worden nergens vastgelegd.", locale: app.interfaceLanguage.locale),
                                        locale: app.interfaceLanguage.locale,
                                        app.aiProvider.displayName
                                    ))
                                } else {
                                    Text("De opname en transcriptie gebeuren volledig lokaal op deze iPhone — geen cloud, geen externe AI-dienst. Audio wordt alleen tijdelijk lokaal bewaard en na transcriptie verwijderd; gepauzeerde stukken worden nergens vastgelegd.")
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.surface)

                    if app.allowMeetingAI {
                        Section {
                            Toggle("Maak ook AI-notulen", isOn: $makeAIMinutes)
                                .tint(Theme.accent)
                        } footer: {
                            if app.showHelpTips {
                                Text(String(
                                    format: L10n.string( "Standaard uit. Alleen voor deze vergadering wordt na afloop de transcripttekst naar %@ gestuurd; audio wordt nooit verstuurd.", locale: app.interfaceLanguage.locale),
                                    locale: app.interfaceLanguage.locale,
                                    app.aiProvider.displayName
                                ))
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }

                    Section("Transcriptietaal") {
                        TranscriptionLanguageMenu(selection: $app.transcriptionLanguage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(Theme.surface)
                }
                .scrollContentBackground(.hidden)
                meetingRecordBar
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Wordmark(size: 20)
            }
        }
        .onAppear(perform: seedOwnContact)
        .sheet(isPresented: $showPrivacyInfo) {
            MeetingPrivacyInfoSheet(makeAIMinutes: app.allowMeetingAI && makeAIMinutes)
                .environmentObject(app)
                .environment(\.locale, app.interfaceLanguage.locale)
                .preferredColorScheme(app.appearance.preferredColorScheme)
        }
        .navigationDestination(isPresented: $started) {
            MeetingRecordView(
                participants: sessionParticipants,
                makeAIMinutes: app.allowMeetingAI && makeAIMinutes,
                language: app.transcriptionLanguage
            )
        }
    }

    private var meetingPageHeader: some View {
        HStack(spacing: 12) {
            Text("Notulen")
                .font(ThemeFont.ui(34, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                showPrivacyInfo = true
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Uitleg over privacy en notulen")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// De start van een notule is bewust losgezet van deelnemersbeheer: dezelfde
    /// grote, rustige opnameknop als op Notities, maar met een heldere actie-naam.
    private var meetingRecordBar: some View {
        VStack(spacing: 0) {
            Button {
                startMeeting()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(canStart ? Theme.accent : Theme.textTertiary, lineWidth: 6)
                        .frame(width: 112, height: 112)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canStart ? Theme.accent : Theme.textTertiary)
                        .frame(width: 48, height: 48)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .accessibilityLabel("Start notulen-opname")

            if !app.modelStatus.isReady {
                Text("Download eerst het spraakmodel via Opnemen.")
                    .font(ThemeFont.ui(13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 9)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: Theme.Metrics.hairline)
        }
    }

    private func seedOwnContact() {
        guard !seededOwnContact else { return }
        seededOwnContact = true
        guard let own = app.meetingContacts.first(where: \.isMe) else { return }
        rows = []
        add(own)
    }

    private func add(_ contact: SavedMeetingContact) {
        guard !rows.contains(where: {
            $0.name.caseInsensitiveCompare(contact.name) == .orderedSame
                && $0.email.caseInsensitiveCompare(contact.email) == .orderedSame
        }) else { return }
        rows.append(Row(name: contact.name, email: contact.email))
    }

    private func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    private func startMeeting() {
        var contacts = app.meetingContacts
        for row in rows where row.saveContact && !isStoredContact(row) {
            guard let participant = row.participant(
                defaultName: L10n.string( "Deelnemer", locale: app.interfaceLanguage.locale)
            ) else { continue }
            contacts = MeetingContactList.saving(participant, in: contacts)
        }
        if contacts != app.meetingContacts {
            app.meetingContacts = contacts
        }
        started = true
    }

    private func isStoredContact(_ row: Row) -> Bool {
        let email = row.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return app.meetingContacts.contains {
            $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(email) == .orderedSame
        }
    }
}
