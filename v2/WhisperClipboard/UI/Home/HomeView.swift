import SwiftUI

/// NightStory-styled Home placeholder for milestone M0.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            statusPill
            actionGrid
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 460)
        .background(NightStory.bg)
    }

    // MARK: - Sections

    private var header: some View {
        // Brand rule: "Whisper Clipboard" in Merriweather bold marine with a
        // terra-colored trailing period.
        (
            Text("Whisper Clipboard")
                .foregroundStyle(NightStory.marine)
            + Text(".")
                .foregroundStyle(NightStory.terra)
        )
        .font(NightStoryFont.heading(size: 30, weight: .bold))
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(environment.appState.isRecording ? NightStory.terra : NightStory.softblue)
                .frame(width: 8, height: 8)
            Text(environment.appState.statusText)
                .font(NightStoryFont.body(size: 13, weight: .medium))
                .foregroundStyle(NightStory.marine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NightStory.lightterra.opacity(0.6))
        .clipShape(Capsule())
    }

    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ActionCard(symbol: "mic", title: "Dicteren", subtitle: "Spreek in en plak de tekst")
            ActionCard(symbol: "folder", title: "Bestanden openen", subtitle: "Transcribeer audio- of videobestanden")
            ActionCard(symbol: "clock.arrow.circlepath", title: "Geschiedenis", subtitle: "Eerdere transcripties terugvinden")
            ActionCard(symbol: "captions.bubble", title: "Live ondertitels", subtitle: "Realtime ondertitels op je scherm")
        }
        .disabled(true)
        .opacity(0.9)
    }

    private var footer: some View {
        Text("NightStory · 2026")
            .font(NightStoryFont.body(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
}
