import SwiftUI

struct DynamicsFollowingPeopleRail: View {
    let people: [DynamicFollowingPerson]
    let selectedMID: Int?
    let selectedPerson: DynamicFollowingPerson?
    let isLoading: Bool
    let hasLoaded: Bool
    let hasMore: Bool
    let failure: String?
    let usesAccessibilityLayout: Bool
    let onSelectAll: () -> Void
    let onSelect: (DynamicFollowingPerson) -> Void
    let onMore: () -> Void
    let onLoadMore: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Group {
            if usesAccessibilityLayout {
                accessibilityControls
            } else {
                avatarRail
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var avatarRail: some View {
        HStack(spacing: 0) {
            allDynamicsButton
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    recentPeopleContent
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
            moreFollowingButton
        }
        .frame(minHeight: 88)
    }

    private var accessibilityControls: some View {
        HStack(spacing: 8) {
            Button(action: onSelectAll) {
                Label("All Dynamics", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            .accessibilityAddTraits(selectedMID == nil ? .isSelected : [])

            Button(action: onMore) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPerson?.displayName ?? String(localized: "More Following"))
                        .appFont(.messageTitle)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.leading)
                    Text("Choose Following Person")
                        .appFont(.messageMeta)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            .accessibilityLabel(Text("More Following"))
            .accessibilityValue(selectedPerson.map { Text($0.displayName) } ?? Text(""))
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var recentPeopleContent: some View {
        if !people.isEmpty {
            ForEach(people) { person in
                personButton(person)
                    .onAppear {
                        if person.id == people.last?.id, hasMore, failure == nil {
                            onLoadMore()
                        }
                    }
            }
        } else if isLoading {
            loadingPlaceholders
        } else if let failure {
            VStack(spacing: 4) {
                Text(failure)
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .appFont(.messageMeta)
            }
            .frame(width: 120)
            .frame(minHeight: 72)
        } else if hasLoaded {
            VStack(spacing: 6) {
                Text("No recent updates")
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if hasMore {
                    Button("Load More Updates", action: onLoadMore)
                        .appFont(.messageMeta)
                }
            }
            .frame(minWidth: 104, minHeight: 72)
        } else {
            Button("Retry", action: onRetry)
                .frame(minWidth: 104, minHeight: 72)
        }

        if !people.isEmpty, isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 68)
        } else if !people.isEmpty, let failure {
            VStack(spacing: 4) {
                Text(failure)
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .appFont(.messageMeta)
            }
            .frame(width: 120)
            .frame(minHeight: 68)
        } else if !people.isEmpty, hasMore {
            // A duplicate-only page cannot produce another tail appearance.
            Button("Load More Updates", action: onLoadMore)
                .appFont(.messageMeta)
                .frame(minWidth: 104, minHeight: 68)
        }
    }

    private var loadingPlaceholders: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(spacing: 6) {
                    Circle()
                        .fill(Color.imagePlaceholder)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: AppRadius.badge)
                        .fill(Color.imagePlaceholder)
                        .frame(width: 42, height: 8)
                }
                .frame(width: 62)
                .frame(minHeight: 68)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading recent people"))
    }

    private var allDynamicsButton: some View {
        let isSelected = selectedMID == nil
        return Button(action: onSelectAll) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.biliAccent : .secondary)
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.biliAccent.opacity(0.14) : AppFill.inset, in: Circle())
                    .appValueFeedback(value: isSelected)
                Text("All Dynamics")
                    .appFont(.messageMeta)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.biliAccent : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 68, alignment: .top)
            }
            .frame(width: 76)
            .frame(minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("All Dynamics"))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var moreFollowingButton: some View {
        Button(action: onMore) {
            VStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(AppFill.inset, in: Circle())
                Text("More Following")
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 68, alignment: .top)
            }
            .frame(width: 76)
            .frame(minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("More Following"))
        .accessibilityValue(selectedPerson.map { Text($0.displayName) } ?? Text(""))
    }

    private func personButton(_ person: DynamicFollowingPerson) -> some View {
        let isSelected = selectedMID == person.mid
        return Button { onSelect(person) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AvatarImage(urlString: person.face, size: 44)
                        .overlay {
                            Circle()
                                .stroke(Color.biliAccent, lineWidth: 2)
                                .padding(-2)
                                .opacity(isSelected ? 1 : 0)
                                .appValueFeedback(value: isSelected)
                        }
                    if person.hasUpdate {
                        Circle()
                            .fill(Color.biliAccent)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: 48, height: 44)
                Text(person.displayName)
                    .appFont(.messageMeta)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.biliAccent : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 66, alignment: .top)
            }
            .frame(width: 70)
            .frame(minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(person.displayName))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct DynamicsFollowingPeoplePickerSheet: View {
    @Bindable var catalog: DynamicsFollowingPeopleCatalog
    let selectedMID: Int?
    let onSelect: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { select(nil) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text("All Followed Dynamics")
                                .appFont(.messageBody)
                            Spacer()
                            selectionMark(isSelected: selectedMID == nil)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedMID == nil ? .isSelected : [])
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    recentUpdatesSection
                }

                followingSection
            }
            .listRowBackground(AppFill.card)
            .listStyle(.insetGrouped)
            .readableFormWidth(.ambientBrowse)
            .navigationTitle("Choose Following Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                async let recent = catalog.loadRecentPeopleIfNeeded()
                await catalog.loadFollowingPeopleIfNeeded()
                await recent
            }
        }
    }

    @ViewBuilder
    private var recentUpdatesSection: some View {
        Section("Recent Updates") {
            if catalog.isLoadingRecent, catalog.recentPeople.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.imagePlaceholder)
                                    .frame(width: 48, height: 48)
                                RoundedRectangle(cornerRadius: AppRadius.badge)
                                    .fill(Color.imagePlaceholder)
                                    .frame(width: 56, height: 10)
                            }
                            .frame(width: 76)
                            .frame(minHeight: 84)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Loading recent people"))
            } else if let failure = catalog.recentFailure, catalog.recentPeople.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure)
                        .appFont(.messageMeta)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await catalog.loadMoreRecentPeople() } }
                }
                .frame(minHeight: 56, alignment: .leading)
            } else if catalog.recentPeople.isEmpty, catalog.recentHasLoaded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No recent updates")
                        .appFont(.messageBody)
                    if catalog.recentHasMore {
                        Button("Load More Updates") { Task { await catalog.loadMoreRecentPeople() } }
                    }
                }
                .frame(minHeight: 56, alignment: .leading)
            } else if catalog.recentPeople.isEmpty {
                Button("Retry") { Task { await catalog.loadMoreRecentPeople() } }
                    .frame(minHeight: 56)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(catalog.recentPeople) { person in
                            avatarChoice(person)
                        }
                        if catalog.isLoadingRecent {
                            ProgressView().frame(width: 44, height: 56)
                        } else if let failure = catalog.recentFailure {
                            Button("Retry") { Task { await catalog.loadMoreRecentPeople() } }
                                .accessibilityValue(Text(failure))
                        } else if catalog.recentHasMore {
                            Button("Load More Updates") {
                                Task { await catalog.loadMoreRecentPeople() }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var followingSection: some View {
        Section("All Following") {
            if catalog.followingPeople.isEmpty, catalog.isLoadingFollowing {
                SimpleRowPlaceholderList(
                    count: 6,
                    spacing: 16,
                    showsAvatar: true,
                    avatarSize: 40,
                    accessibilityLabel: String(
                        format: String(localized: "Loading %@"),
                        String(localized: "All Following")
                    )
                )
                .padding(.vertical, 4)
            }

            ForEach(catalog.followingPeople) { person in
                personChoice(person)
                    .onAppear {
                        if person.id == catalog.followingPeople.last?.id,
                           catalog.followingHasMore,
                           catalog.followingFailure == nil {
                            Task { await catalog.loadMoreFollowingPeople() }
                        }
                    }
            }

            if let failure = catalog.followingFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure)
                        .appFont(.messageMeta)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await catalog.loadMoreFollowingPeople() } }
                }
                .frame(minHeight: 56, alignment: .leading)
            } else if catalog.followingPeople.isEmpty,
                      catalog.followingHasLoaded, !catalog.followingHasMore {
                ContentUnavailableView(
                    "No People You Follow",
                    systemImage: "person.2"
                )
            } else if catalog.followingHasMore, !catalog.isLoadingFollowing {
                Button("Load More Following") {
                    Task { await catalog.loadMoreFollowingPeople() }
                }
                .frame(minHeight: 56, alignment: .leading)
            } else if catalog.isLoadingFollowing, !catalog.followingPeople.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(minHeight: 56)
            } else if !catalog.followingHasLoaded, !catalog.isLoadingFollowing {
                Button("Retry") { Task { await catalog.loadMoreFollowingPeople() } }
                    .frame(minHeight: 56)
            }
        }
    }

    private func avatarChoice(_ person: DynamicFollowingPerson) -> some View {
        let isSelected = selectedMID == person.mid
        return Button { select(person.mid) } label: {
            VStack(spacing: 6) {
                AvatarImage(urlString: person.face, size: 48)
                    .overlay {
                        Circle().strokeBorder(Color.biliAccent, lineWidth: 2)
                            .opacity(isSelected ? 1 : 0)
                            .appValueFeedback(value: isSelected)
                    }
                Text(person.displayName)
                    .appFont(.messageMeta)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 72, height: 30, alignment: .top)
            }
            .frame(width: 76)
            .frame(minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(person.displayName))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func personChoice(_ person: DynamicFollowingPerson) -> some View {
        let isSelected = selectedMID == person.mid
        return Button { select(person.mid) } label: {
            HStack(spacing: 12) {
                AvatarImage(urlString: person.face, size: 40)
                Text(person.displayName)
                    .appFont(.messageBody)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                selectionMark(isSelected: isSelected)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(person.displayName))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func selectionMark(isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundStyle(Color.biliAccent)
                .accessibilityHidden(true)
        }
    }

    private func select(_ mid: Int?) {
        onSelect(mid)
        dismiss()
    }
}
