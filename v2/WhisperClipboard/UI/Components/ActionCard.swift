import SwiftUI

/// Reusable NightStory action card: an SF Symbol icon over a title and subtitle.
///
/// White card surface, 1px sand border, radius 12, subtle shadow. On hover the
/// border shifts to terra. Cards are disabled in M0 (placeholders).
struct ActionCard: View {
    let symbol: String
    let title: String
    let subtitle: String

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(NightStory.terra)

            Text(title)
                .font(NightStoryFont.body(size: 15, weight: .semibold))
                .foregroundStyle(NightStory.marine)

            Text(subtitle)
                .font(NightStoryFont.body(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .background(NightStory.card)
        .clipShape(RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NightStoryMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(isHovering ? NightStory.terra : NightStory.sand, lineWidth: 1)
        )
        .nightStoryShadowSmall()
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
    }
}
