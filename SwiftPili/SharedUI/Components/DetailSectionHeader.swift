import SwiftUI

/// A section heading on a detail page — "Parts 11", "Related" — with an
/// optional count beside the title and an optional trailing control.
///
/// One definition so the video and bangumi pages title their sections the
/// same way; the type comes from the shared `AppTextRole` table.
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
