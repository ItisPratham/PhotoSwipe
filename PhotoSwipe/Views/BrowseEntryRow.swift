import SwiftUI

/// A single tappable entry card on the Browse tab — an icon, a title, an
/// optional subtitle, and a trailing chevron. Purely presentational: callers
/// wrap it in the `NavigationLink(value:)` that routes into the deck, so all
/// four Browse entries (Albums, Videos, Biggest files, Duplicates) share one
/// consistent layout instead of repeating the same stack four times.
struct BrowseEntryRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.cardPadding)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

#Preview {
    VStack(spacing: 12) {
        BrowseEntryRow(title: "Albums", systemImage: "rectangle.stack")
        BrowseEntryRow(title: "Biggest files",
                       subtitle: "Photos & videos, largest first",
                       systemImage: "arrow.up.arrow.down.circle")
    }
    .padding()
}
