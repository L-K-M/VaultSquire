import SwiftUI

/// The badge at the head of an item row.
///
/// It draws the site's own icon when one has been fetched, a letter on a
/// colour derived from the site when one has not, and the category's symbol for
/// an item with no site at all. The monogram is not a placeholder waiting on
/// the network: with site icons off — the default — it is the whole feature,
/// and it is deterministic, so a given login keeps its colour across launches
/// and stays recognizable at a glance.
struct ItemIconView: View {
    let identity: ItemIconIdentity
    let category: VaultItemCategory
    var size: CGFloat = 26

    @EnvironmentObject private var siteIcons: SiteIconStore

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
            .accessibilityHidden(true)
            // Keyed on the host so a recycled row re-requests for its new site
            // rather than keeping the previous one's.
            .task(id: identity.host) { await siteIcons.load(identity.host) }
    }

    @ViewBuilder
    private var content: some View {
        if let image = siteIcons.image(for: identity.host) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.16)
        } else if identity.host != nil {
            Text(identity.monogram)
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
        } else {
            Image(systemName: category.symbolName)
                .font(.system(size: size * 0.5))
                .foregroundStyle(tint)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    }

    /// The row's colour. An item with no site takes the neutral accent rather
    /// than a hue hashed from its title, so the coloured rows are exactly the
    /// ones a colour means something for.
    private var tint: Color {
        guard identity.host != nil else { return .secondary }
        return Color(hue: identity.hue, saturation: 0.62, brightness: 0.72)
    }
}
