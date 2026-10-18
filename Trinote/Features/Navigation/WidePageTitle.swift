import SwiftUI

extension View {
    /// The page's navigation title. Beside the note tree (iPad, Mac) it is drawn like the tree's own
    /// large title, at the same height and size, so the two headings line up; the system large
    /// title sat a few points lower. On iPhone the system large title stays.
    /// `gapBelow` is the space before the page's content; lists starting with a section margin of
    /// their own (Recents' segments) pass less.
    func widePageTitle(_ title: String, gapBelow: CGFloat = 11) -> some View {
        modifier(WidePageTitle(title: title, gapBelow: gapBelow))
    }
}

private struct WidePageTitle: ViewModifier {
    @Environment(\.appFont) private var appFont
    let title: String
    let gapBelow: CGFloat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            // No navigation title and a compact bar, exactly like Home: on a Mac the split view gives
            // both columns the taller bar of either, so any difference moved the tree too.
            content
                .toolbarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text(title)
                        .headingFont(34)
                        .foregroundStyle(Color.trinoteTextPrimary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        // Same box as the tree's title row (46 pt, text centered) and the compact
                        // section gap below it, so the first card starts where the tree's does.
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .padding(.leading, WidePageTitle.leading)
                        .padding(.bottom, gapBelow)
                        .background(Color.trinoteGround)
                }
        } else {
            content.navigationTitle(title)
        }
    }

    /// The tree's list margin plus its 4 pt row inset.
    static let leading: CGFloat = 24
}
