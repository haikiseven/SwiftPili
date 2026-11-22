import SwiftUI

/// The glass bar under an iPad landscape detail page's hero player: the title
/// on the first line, the creator (leading) and the action row (trailing) on
/// the second.
///
/// It sits UNDER the player, never over the video, which carries the player's
/// transport row. The page reserves its measured height in the hero geometry
/// so the whole bar is visible at scroll top (user decision D1).
struct CinematicHeroBar<Title: View, Leading: View, Trailing: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            title()
            HStack(spacing: AppSpacing.m) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
        }
        .padding(.vertical, AppSpacing.m)
        .padding(.horizontal, AppSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardSurface(in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
    }
}
