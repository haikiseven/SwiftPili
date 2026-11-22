import SwiftUI

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
