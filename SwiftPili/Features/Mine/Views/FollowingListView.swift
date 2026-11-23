import SwiftUI

struct FollowingListView: View {
    enum Mode: Equatable {
        case following
        case followers
    }

    struct FollowingItem: Identifiable {
        let mid: Int
        let uname: String
        let face: String
        let sign: String?
        var isFollowing: Bool
        var id: Int { mid }
    }

    var mode: Mode = .following
    var mid: Int?

    @State private var viewModel: FollowingListViewModel
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var groupTarget: FollowingItem?
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.authManager) private var authManager
    @Environment(\.accountManager) private var accountManager

    init(mode: Mode = .following, mid: Int? = nil) {
        self.mode = mode
        self.mid = mid
        _viewModel = State(initialValue: FollowingListViewModel(mode: mode, mid: mid))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.supportsGroups, !viewModel.tags.isEmpty {
                FollowingGroupChipsBar(
                    tags: viewModel.tags,
                    selectedTag: viewModel.selectedTag,
                    labelForTag: Self.tagDisplayName,
                    onSelectTag: { tagid in
                        viewModel.bind(authManager: authManager, accountManager: accountManager)
                        viewModel.selectTag(tagid)
                    }
                )
                .frame(maxWidth: ReadableWidth.feed, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            FollowingCollectionView(
                rows: viewModel.rowModels,
                placeholderCount: viewModel.showsInitialPlaceholder ? 6 : 0,
                placeholderLabel: loadingAccessibilityLabel,
                footerState: viewModel.footerState,
                paginationGeneration: viewModel.paginationGeneration,
                onRefresh: {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    await viewModel.refresh()
                    return false
                },
                onNearEndAppear: {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    viewModel.requestMore()
                },
                onFooterAction: {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    if let failure = viewModel.loadFailure {
                        viewModel.requestMore(retrying: failure)
                    }
                },
                onSelectUser: { userMid in
                    coordinator.navigate(to: .userSpace(userMid))
                },
                onGroupTap: { userMid in
                    if let user = viewModel.item(withMid: userMid) {
                        groupTarget = user
                    }
                },
                onFollowTap: { userMid in
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    viewModel.toggleFollow(userMid: userMid)
                }
            )
            .overlay {
                if viewModel.items.isEmpty, !viewModel.showsInitialPlaceholder {
                    if let failure = viewModel.loadFailure {
                        failureView(failure)
                    } else if viewModel.page > 1 {
                        if mode == .following {
                            ContentUnavailableView("No People You Follow", systemImage: "person.2")
                        } else {
                            ContentUnavailableView("Followers", systemImage: "person.2")
                        }
                    }
                }
            }
        }
        .appAmbientBrowseBackground()
        .navigationTitle(mode == .following ? Text("Following") : Text("Followers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.supportsGroups {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newGroupName = ""
                        showCreateGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
        }
        .alert(Text("New Group"), isPresented: $showCreateGroup) {
            TextField(String(localized: "Group Name"), text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newGroupName
                Task {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    await viewModel.createGroup(name: name)
                }
            }
        }
        .sheet(item: $groupTarget) { user in
            FollowGroupSheet(user: user, tags: viewModel.tags) {
                Task {
                    viewModel.bind(authManager: authManager, accountManager: accountManager)
                    await viewModel.loadTags()
                    if viewModel.selectedTag != nil { viewModel.reloadForSelectedTag() }
                }
            }
            .appAdaptiveSheet(padSizing: .form)
        }
        .task(id: accountManager.identityRevision) {
            viewModel.bind(authManager: authManager, accountManager: accountManager)
            if viewModel.resetForAccountRevisionIfNeeded(accountManager.identityRevision) {
                groupTarget = nil
            }
            await viewModel.loadInitialIfNeeded()
        }
    }

    // MARK: - Follow groups

    static func tagDisplayName(_ tag: RelationTag) -> String {
        switch tag.tagid {
        case -10: String(localized: "Special Follow")
        case 0: String(localized: "Default Group")
        default: tag.name ?? "\(tag.tagid)"
        }
    }
}

private extension FollowingListView {
    var loadingAccessibilityLabel: String {
        let title = mode == .following ? String(localized: "Following") : String(localized: "Followers")
        return String(format: String(localized: "Loading %@"), title)
    }

    @ViewBuilder
    private func failureView(_ receipt: FollowingListViewModel.FailureReceipt) -> some View {
        FollowingFailureOverlay(
            kind: receipt.failure,
            isFollowingMode: mode == .following,
            onRetry: {
                viewModel.bind(authManager: authManager, accountManager: accountManager)
                viewModel.requestMore(retrying: receipt)
            }
        )
    }
}
