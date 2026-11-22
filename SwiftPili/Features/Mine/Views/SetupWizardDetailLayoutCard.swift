import SwiftUI

/// The iPad-only setup-wizard choice of how landscape detail pages open. Writes
/// the same `DetailStagePreferences` key Settings binds to.
struct SetupWizardDetailLayoutCard: View {
    @AppStorage(DetailStagePreferences.startsInStageKey) private var detailStartsInStage = false

    var body: some View {
        wizardCard(title: "iPad Landscape Detail Layout", icon: "rectangle.split.2x1") {
            VStack(spacing: 6) {
                detailLayoutRow(
                    title: "Hero First",
                    detail: "Pages open with a large preview; scroll down to reveal comments.",
                    startsInStage: false
                )
                detailLayoutRow(
                    title: "Direct Stage",
                    detail: "Video and comments appear side by side as soon as a page opens.",
                    startsInStage: true
                )
            }
        }
    }

    private func detailLayoutRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        startsInStage: Bool
    ) -> some View {
        let isSelected = detailStartsInStage == startsInStage
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        return Button {
            detailStartsInStage = startsInStage
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(.rowTitle).foregroundStyle(.primary)
                    Text(detail).appFont(.rowMeta).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Color.biliAccent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? AppFill.inset : Color.clear, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
