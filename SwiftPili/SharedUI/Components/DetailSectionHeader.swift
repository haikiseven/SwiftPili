import SwiftUI

struct DetailSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .appFont(.sectionTitle)
                .fontWeight(.semibold)
            if let count {
                Text("\(count)")
                    .appFont(.messageMeta)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension DetailSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, count: Int? = nil) {
        self.init(title: title, count: count, trailing: { EmptyView() })
    }
}
