import SwiftUI

struct DetailCompanionSplitLayout<Primary: View, Companion: View>: View {
    static var primaryHorizontalPadding: CGFloat { DetailStageLayout.outerMargin + AppSpacing.xs }
    static var primaryTopPadding: CGFloat { DetailStageLayout.outerMargin }
    static var primaryBottomPadding: CGFloat { DetailStageLayout.outerMargin + AppSpacing.s }
    static var companionMinimumWidth: CGFloat { 360 }
    static var companionMaximumWidth: CGFloat { 400 }
    static var companionPreferredFraction: CGFloat { 0.34 }

    let containerWidth: CGFloat
    var showsCompanion: Bool = true
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let companion: () -> Companion

    static func companionWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return companionMinimumWidth }
        let preferred = (containerWidth * companionPreferredFraction).rounded()
        return min(max(preferred, companionMinimumWidth), companionMaximumWidth)
    }

    static func primaryContentWidth(containerWidth: CGFloat, showsCompanion: Bool = true) -> CGFloat {
        let companionReserved = showsCompanion
            ? companionWidth(containerWidth: containerWidth) + DetailStageLayout.outerMargin
            : 0
        let column = containerWidth - companionReserved - primaryHorizontalPadding * 2
        return max(0, min(column, ReadableWidth.feed))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                primary()
                    .frame(maxWidth: ReadableWidth.feed, alignment: .leading)
                    .padding(.horizontal, Self.primaryHorizontalPadding)
                    .padding(.top, Self.primaryTopPadding)
                    .padding(.bottom, Self.primaryBottomPadding)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsCompanion {
                companionCard
                    .padding(.top, AppSpacing.l)
                    .padding(.bottom, DetailStageLayout.outerMargin)
                    .padding(.trailing, DetailStageLayout.outerMargin)
            }
        }
    }

    private var companionCard: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return companion()
            .frame(width: Self.companionWidth(containerWidth: containerWidth))
            .frame(maxHeight: .infinity)
            .background(shape.fill(AppFill.card))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.05), radius: 14, y: 4)
            .clipShape(shape)
    }
}

extension View {
    func detailContainerSize(_ update: @escaping (CGSize) -> Void) -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            update(size)
        }
    }
}
