import SwiftUI

struct SetupWizardDetailLayoutCard: View {
    @AppStorage(DetailStagePreferences.startsInStageKey) private var detailStartsInStage = false

    var body: some View {
        wizardCard(title: "iPad Detail Layout", icon: "rectangle.split.2x1") {
            VStack(spacing: 6) {
                detailLayoutRow(title: "Hero First", startsInStage: false)
                detailLayoutRow(title: "Direct Stage", startsInStage: true)
            }
        }
    }

    private func detailLayoutRow(
        title: LocalizedStringKey,
        startsInStage: Bool
    ) -> some View {
        let isSelected = detailStartsInStage == startsInStage
        let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        return Button {
            detailStartsInStage = startsInStage
        } label: {
            HStack {
                Text(title).appFont(.rowTitle).foregroundStyle(.primary)
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
