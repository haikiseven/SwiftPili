import SwiftUI

/// Rendering and tap forwarding only; the detail retains list/source ownership.
struct MomentForwardRow: View {
    let forward: DynamicForwardItem
    let openPost: (String) -> Void
    let openProfile: (Int) -> Void

    private let avatarSize: CGFloat = 36
    private let rowSpacing: CGFloat = 10

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedLayout
        } else {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                stackedLayout
            }
        }
    }

    private var horizontalLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: rowSpacing) {
                profileButton
                    .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                timestamp
                    .fixedSize(horizontal: true, vertical: false)
                postButton
            }
            forwardText
                .padding(.leading, avatarSize + rowSpacing)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            profileButton
            HStack {
                Spacer(minLength: avatarSize + rowSpacing)
                timestamp
                Spacer(minLength: 8)
                postButton
            }
            forwardText
                .padding(.leading, avatarSize + rowSpacing)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var profileButton: some View {
        if let mid = forward.user.numericMID, mid > 0 {
            Button {
                openProfile(mid)
            } label: {
                identity
            }
            .buttonStyle(.plain)
        } else {
            identity
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: rowSpacing) {
            AvatarImage(urlString: forward.user.face, size: avatarSize)
            Text(forward.user.name ?? String(localized: "Unknown User"))
                .appFont(.messageTitle)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var timestamp: some View {
        if !forward.pubTime.isEmpty {
            Text(verbatim: forward.pubTime)
                .appFont(.messageMeta)
                .foregroundStyle(.secondary)
        }
    }

    private var postButton: some View {
        Button {
            openPost(forward.idStr)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .appFont(.messageMeta)
                .foregroundStyle(Color.primary.opacity(0.68))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("Open reposted dynamic"))
    }

    @ViewBuilder
    private var forwardText: some View {
        if DynamicRichBodyView.hasContent(
            text: forward.desc.text, nodes: forward.desc.richTextNodes
        ) {
            DynamicRichBodyView(
                text: forward.desc.text,
                nodes: forward.desc.richTextNodes,
                sourceID: forward.idStr,
                font: .body,
                lineSpacing: 3,
                lineLimit: 3
            )
        }
    }
}

struct MomentReactionRow: View {
    let reaction: DynamicReactionResult.ReactionItem
    let openProfile: (Int) -> Void

    @ViewBuilder
    var body: some View {
        if let mid = reaction.numericMID, mid > 0 {
            Button {
                openProfile(mid)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            AvatarImage(urlString: reaction.face, size: 36)
            Text(reaction.name ?? String(localized: "Unknown User"))
                .appFont(.messageTitle)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Spacer()
            if let action = reaction.action, !action.isEmpty {
                Text(verbatim: action)
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct MomentInteractionSelector: View {
    let selection: Binding<MomentDetailView.InteractionSection>
    let isAccessibilitySize: Bool
    let label: (MomentDetailView.InteractionSection) -> (name: LocalizedStringKey, total: Int)

    @AppMotion private var motion
    @State private var userPicks = 0
    @Namespace private var indicator

    @ViewBuilder
    var body: some View {
        if isAccessibilitySize {
            picker
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(MomentDetailView.InteractionSection.allCases, id: \.self) { target in
                        tabButton(target)
                    }
                }
                .background {
                    Capsule()
                        .fill(AccentStore.shared.badgeFill)
                        .matchedGeometryEffect(id: selection.wrappedValue, in: indicator, isSource: false)
                        .animation(
                            motion.animation(normal: .snappy(duration: 0.2, extraBounce: 0)),
                            value: selection.wrappedValue
                        )
                }
                .padding(.horizontal, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .appSelectionHaptic(userPicks: userPicks)
        }
    }

    private func tabButton(_ target: MomentDetailView.InteractionSection) -> some View {
        let isSelected = selection.wrappedValue == target
        let entry = label(target)
        return Button {
            guard selection.wrappedValue != target else { return }
            userPicks &+= 1
            selection.wrappedValue = target
        } label: {
            VStack(spacing: 5) {
                tabLabel(entry: entry, isSelected: true)
                    .hidden()
                    .overlay {
                        tabLabel(entry: entry, isSelected: isSelected)
                    }
                Color.clear
                    .frame(width: 18, height: 3)
                    .matchedGeometryEffect(id: target, in: indicator)
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tabLabel(entry: (name: LocalizedStringKey, total: Int), isSelected: Bool) -> some View {
        HStack(spacing: 4) {
            Text(entry.name)
                .font(.callout.weight(isSelected ? .bold : .medium))
            if entry.total > 0 {
                Text(FormatUtils.viewCount(entry.total))
                    .appFont(.screenStat)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .lineLimit(1)
    }

    private var picker: some View {
        Picker("Moment Interactions", selection: selection) {
            ForEach(MomentDetailView.InteractionSection.allCases, id: \.self) { target in
                let entry = label(target)
                let suffix = entry.total > 0 ? " " + FormatUtils.viewCount(entry.total) : ""
                Text("\(Text(entry.name))\(Text(verbatim: suffix))")
                    .tag(target)
            }
        }
    }
}

struct MomentInteractionUnavailableState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
        }
    }
}
