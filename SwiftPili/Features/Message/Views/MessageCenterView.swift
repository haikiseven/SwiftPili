import SwiftUI

@MainActor
private enum MessageCommentNavigation {
    static func open(
        uri: String?,
        nativeURI: String?,
        payload: MessageCommentAnchorPayload,
        coordinator: AppCoordinator,
        context: ContentLinkContext?
    ) {
        guard context?.isCurrent() != false else { return }
        coordinator.contentLinks.cancel()
        if let anchor = payload.commentAnchor {
            coordinator.navigate(to: anchor)
            return
        }
        guard let raw = nativeURI ?? uri,
              let url = URL(string: raw)
        else { return }
        coordinator.handle(url: url, context: context)
    }
}

enum MessageSelection: Hashable {
    case category(MessageTab)
    case chat(talkerId: Int, name: String, face: String?)

    var talkerId: Int? {
        if case .chat(let talkerId, _, _) = self { talkerId } else { nil }
    }
}

enum MessageTab: String, CaseIterable {
    case reply = "Replies"
    case at = "Mentions"
    case like = "Likes"
    case system = "System"

    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }

    var icon: String {
        switch self {
        case .reply: "arrowshape.turn.up.left.fill"
        case .at: "at"
        case .like: "heart.fill"
        case .system: "bell.fill"
        }
    }

    var tint: Color {
        switch self {
        case .reply: .blue
        case .at: .orange
        case .like: .pink
        case .system: .purple
        }
    }
}

struct MessageCenterView: View {
    @State private var viewModel = MessageCenterViewModel()
    @Environment(AppCoordinator.self) private var coordinator

    @State private var selection: MessageSelection?

    var body: some View {
        GeometryReader { proxy in
            let usesSplit = DetailSplitPolicy.usesSplit(
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                containerSize: proxy.size
            )
            Group {
                if usesSplit {
                    splitLayout(containerWidth: proxy.size.width)
                } else {
                    sidebarList(usesSplit: false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .appAmbientBrowseBackground()
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: AccountManager.shared.identityRevision) { await viewModel.loadInitial() }
    }

    private func sidebarList(usesSplit: Bool) -> some View {
        let sessions = chatSessions
        let tabs = MessageTab.allCases
        return ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                VStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                        let isSelected = usesSplit && selection == .category(tab)
                        let nextSelected = usesSplit && index + 1 < tabs.count
                            && selection == .category(tabs[index + 1])
                        categoryEntry(tab, usesSplit: usesSplit, isSelected: isSelected)
                        if index < tabs.count - 1, !isSelected, !nextSelected {
                            Divider()
                                .opacity(0.35)
                                .padding(.leading, usesSplit ? 70 : 66)
                        }
                    }
                }
                .padding(.vertical, usesSplit ? 4 : 0)
                .background(
                    AppFill.card,
                    in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                )

                chatsSection(sessions, usesSplit: usesSplit)
            }
            .padding(.horizontal, usesSplit ? AppSpacing.m : AppSpacing.l)
            .padding(.vertical, AppSpacing.l)
            .frame(maxWidth: usesSplit ? .infinity : ReadableWidth.feed)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await viewModel.loadInitial() }
    }

    private func categoryCard(_ tab: MessageTab, isSelected: Bool = false) -> some View {
        let unread = unreadCount(for: tab)
        return HStack(spacing: 12) {
            Circle()
                .fill(tab.tint.opacity(isSelected ? 0.22 : 0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: tab.icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tab.tint)
                }

            Text(tab.title)
                .appFont(.messageTitle)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? Color.biliAccent : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if unread > 0 {
                unreadBadge(unread)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.biliAccent) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var chatSessions: [SessionListResult.SessionItem] {
        viewModel.sessions.filter {
            ($0.systemMsgType ?? 0) == 0 && $0.talkerId < (1 << 40)
        }
    }

    // MARK: - Category entries

    @ViewBuilder
    private func destination(for tab: MessageTab) -> some View {
        switch tab {
        case .reply:
            ReplyListView(viewModel: viewModel, coordinator: coordinator)
                .appAmbientBrowseBackground()
                .navigationTitle("Replies")
                .navigationBarTitleDisplayMode(.inline)
        case .at:
            AtListView(viewModel: viewModel, coordinator: coordinator)
                .appAmbientBrowseBackground()
                .navigationTitle("Mentions")
                .navigationBarTitleDisplayMode(.inline)
        case .like:
            LikeListView(viewModel: viewModel, coordinator: coordinator)
                .appAmbientBrowseBackground()
                .navigationTitle("Likes")
                .navigationBarTitleDisplayMode(.inline)
        case .system:
            SystemListView(viewModel: viewModel, coordinator: coordinator)
                .appAmbientBrowseBackground()
                .navigationTitle("System")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Chat rows

    private func sessionRow(_ session: SessionListResult.SessionItem, usesSplit: Bool) -> some View {
        let resolved = viewModel.sessionUsers[session.talkerId]
        let face = session.accountInfo?.face
            ?? resolved?.face
            ?? session.groupCover
        let name = session.accountInfo?.name
            ?? resolved?.name
            ?? session.groupName

        let displayName = name ?? String(localized: "User \(session.talkerId)")
        let isSelected = usesSplit && selection?.talkerId == session.talkerId

        return HStack(spacing: 12) {
            SessionAvatarView(talkerId: session.talkerId, name: name, face: face)
                .onTapGesture {
                    coordinator.navigate(to: .userSpace(session.talkerId))
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayName)
                        .appFont(.messageTitle)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Color.biliAccent : Color.primary)
                        .lineLimit(1)
                    Spacer()
                    if let ts = sessionTimestamp(session) {
                        Text(FormatUtils.timeAgo(from: ts))
                            .appFont(.messageMeta)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack {
                    Text(preview(for: session.lastMsg))
                        .appFont(.messageBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let unread = session.unreadCount, unread > 0 {
                        unreadBadge(unread)
                    }
                }
            }
        }
        .padding(.horizontal, usesSplit ? 10 : 0)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isSelected {
                Divider()
                    .opacity(0.35)
                    .padding(.leading, usesSplit ? 70 : 60)
            }
        }
        .background(selectionHighlight(isSelected))
        .onTapGesture {
            guard (session.sessionType ?? 1) == 1 else { return }
            if usesSplit {
                selection = .chat(talkerId: session.talkerId, name: displayName, face: face)
            } else {
                coordinator.navigate(to: .chat(
                    talkerId: session.talkerId,
                    name: displayName,
                    face: face
                ))
            }
        }
    }

    private func preview(for msg: SessionListResult.SessionItem.LastMsg?) -> String {
        msg?.displayContent ?? ""
    }

    private func sessionTimestamp(_ session: SessionListResult.SessionItem) -> Int? {
        guard let ts = session.lastMsg?.timestamp ?? session.sessionTs else { return nil }
        return ts > 4_000_000_000 ? ts / 1_000_000 : ts
    }

    private func unreadBadge(_ count: Int) -> some View {
        Text("\(count)")
            .appFont(.overlayBadge, monospacedDigit: true)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .frame(minWidth: 20)
            .background(Color.biliAccent, in: Capsule())
    }

    private struct SessionAvatarView: View {
        let talkerId: Int
        let name: String?
        let face: String?
        var isSystemBox = false

        var body: some View {
            if let urlString = face, !urlString.isEmpty {
                AvatarImage(urlString: urlString, size: 48)
            } else {
                fallbackCircle
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            }
        }

        private var fallbackCircle: some View {
            Circle()
                .fill(isSystemBox ? Color.biliAccent.opacity(0.15) : AppFill.inset)
                .overlay {
                    Image(systemName: isSystemBox ? "bell.badge.fill" : "person.fill")
                        .font(.callout)
                        .foregroundStyle(isSystemBox ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.secondary))
                }
        }
    }

    private func unreadCount(for tab: MessageTab) -> Int {
        switch tab {
        case .reply: viewModel.unread?.reply ?? 0
        case .at: viewModel.unread?.at ?? 0
        case .like: viewModel.unread?.like ?? 0
        case .system: viewModel.unread?.sysMsg ?? 0
        }
    }
}

extension MessageCenterView {
    // MARK: - iPad landscape list-detail

    private func sidebarWidth(for containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return 352 }
        return min(max((containerWidth * 0.30).rounded(), 340), 360)
    }

    private func splitLayout(containerWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebarList(usesSplit: true)
                .frame(width: sidebarWidth(for: containerWidth))
            Divider()
                .opacity(0.45)
            splitDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var splitDetail: some View {
        switch selection {
        case .category(let tab):
            VStack(spacing: 0) {
                splitCategoryHeader(tab)
                destination(for: tab)
                    .contentLinks()
                    .id(tab)
            }
        case .chat(let talkerId, let name, let face):
            VStack(spacing: 0) {
                splitChatHeader(talkerId: talkerId, name: name, face: face)
                ChatView(talkerId: talkerId, name: name, face: face)
                    .contentLinks()
                    .id(talkerId)
            }
        case nil:
            splitEmptyState
        }
    }

    private var splitEmptyState: some View {
        VStack(spacing: AppSpacing.m) {
            Circle()
                .fill(AppFill.nested)
                .frame(width: 68, height: 68)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            Text("Select a conversation or notification")
                .appFont(.screenTitle)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text("Choose a notification category or direct message from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, AppSpacing.xl)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func splitCategoryHeader(_ tab: MessageTab) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.m) {
                Circle()
                    .fill(tab.tint.opacity(0.15))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: tab.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tab.tint)
                    }
                Text(tab.title)
                    .appFont(.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.vertical, AppSpacing.m)
            Divider()
                .opacity(0.45)
        }
    }

    private func splitChatHeader(talkerId: Int, name: String, face: String?) -> some View {
        VStack(spacing: 0) {
            Button {
                coordinator.navigate(to: .userSpace(talkerId))
            } label: {
                HStack(spacing: 10) {
                    if let urlString = face, !urlString.isEmpty {
                        AvatarImage(urlString: urlString, size: 32)
                    } else {
                        Circle()
                            .fill(AppFill.inset)
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    Text(name)
                        .appFont(.sectionTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.appControl)
            Divider()
                .opacity(0.45)
        }
    }

    @ViewBuilder
    private func categoryEntry(_ tab: MessageTab, usesSplit: Bool, isSelected: Bool) -> some View {
        if usesSplit {
            Button {
                selection = .category(tab)
            } label: {
                categoryCard(tab, isSelected: isSelected)
                    .background(selectionHighlight(isSelected))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.appControl)
        } else {
            NavigationLink {
                destination(for: tab)
                    .contentLinks()
            } label: {
                categoryCard(tab)
            }
            .buttonStyle(.appControl)
        }
    }

    private func selectionHighlight(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(isSelected ? Color.biliAccent.opacity(0.14) : Color.clear)
    }

    private func chatsSection(
        _ sessions: [SessionListResult.SessionItem],
        usesSplit: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack {
                Text("Chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, usesSplit ? 10 : 4)

            if !AuthManager.shared.isLoggedIn {
                ContentUnavailableView(
                    "Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .padding(.vertical, 24)
            } else {
                if !sessions.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            sessionRow(session, usesSplit: usesSplit)
                        }
                    }
                }

                if let error = viewModel.sessionLoadError {
                    MessageLoadFailureView(message: error) {
                        Task { await viewModel.retrySessions() }
                    }
                } else if sessions.isEmpty {
                    if viewModel.sessionsLoaded && !viewModel.isLoadingSessions {
                        ContentUnavailableView("No Messages", systemImage: "bubble.left.and.bubble.right")
                            .padding(.vertical, 24)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
    }
}

// MARK: - Reply List

private struct ReplyListView: View {
    @Environment(\.contentLinkContext) private var linkContext
    let viewModel: MessageCenterViewModel
    let coordinator: AppCoordinator

    var body: some View {
        MessageNotificationScrollView(
            page: viewModel.replyPage,
            emptyTitle: "No Replies",
            emptyIcon: "arrowshape.turn.up.left",
            refresh: { await viewModel.refreshReplies() },
            loadMore: { await viewModel.loadMoreReplies() },
            retry: { failure in
                if let failure { await viewModel.retryReplies(failure) } else { await viewModel.loadReplies() }
            },
            row: { item in
                replyRow(item).onTapGesture { navigateToSource(item) }
            }
        )
        .task(id: AccountManager.shared.identityRevision) { await viewModel.loadReplies() }
    }

    private func replyRow(_ item: ReplyMessageResult.ReplyMsgItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(urlString: item.user?.avatarURL ?? "", size: 42)
                .onTapGesture {
                    if let mid = item.user?.mid {
                        coordinator.navigate(to: .userSpace(mid))
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.user?.displayName ?? "")
                        .appFont(.messageTitle)
                        .fontWeight(.semibold)
                    Spacer()
                    if let t = item.replyTime {
                        Text(FormatUtils.timeAgo(from: t))
                            .appFont(.messageMeta)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(item.item?.sourceContent ?? String(localized: "replied to you"))
                    .appFont(.messageBody)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if let title = item.item?.targetReplyContent ?? item.item?.title, !title.isEmpty {
                    MessageNotificationQuote(title: title)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .messageRowDivider(inset: 54)
    }

    private func navigateToSource(_ item: ReplyMessageResult.ReplyMsgItem) {
        let message = item.item
        MessageCommentNavigation.open(
            uri: message?.uri,
            nativeURI: message?.nativeUri,
            payload: MessageCommentAnchorPayload(
                uri: message?.uri,
                nativeURI: message?.nativeUri,
                subjectID: message?.subjectId,
                rootID: message?.rootId,
                sourceID: message?.sourceId,
                targetID: message?.targetId,
                businessID: message?.businessId,
                business: message?.business,
                source: "reply"
            ),
            coordinator: coordinator, context: linkContext
        )
    }
}

// MARK: - At List

private struct AtListView: View {
    @Environment(\.contentLinkContext) private var linkContext
    let viewModel: MessageCenterViewModel
    let coordinator: AppCoordinator

    var body: some View {
        MessageNotificationScrollView(
            page: viewModel.atPage,
            emptyTitle: "No Mentions",
            emptyIcon: "at",
            refresh: { await viewModel.refreshAt() },
            loadMore: { await viewModel.loadMoreAt() },
            retry: { failure in
                if let failure { await viewModel.retryAt(failure) } else { await viewModel.loadAt() }
            },
            row: { item in
                atRow(item).onTapGesture { navigateToSource(item) }
            }
        )
        .task(id: AccountManager.shared.identityRevision) { await viewModel.loadAt() }
    }

    private func atRow(_ item: AtMessageResult.AtMsgItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarImage(urlString: item.user?.avatarURL ?? "", size: 42)
                .onTapGesture {
                    if let mid = item.user?.mid {
                        coordinator.navigate(to: .userSpace(mid))
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.user?.displayName ?? "")
                        .appFont(.messageTitle)
                        .fontWeight(.semibold)
                    Spacer()
                    if let t = item.atTime {
                        Text(FormatUtils.timeAgo(from: t))
                            .appFont(.messageMeta)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(item.item?.sourceContent ?? String(localized: "mentioned you"))
                    .appFont(.messageBody)
                    .lineLimit(3)

                if let title = item.item?.title, !title.isEmpty {
                    MessageNotificationQuote(title: title)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .messageRowDivider(inset: 54)
    }

    private func navigateToSource(_ item: AtMessageResult.AtMsgItem) {
        let message = item.item
        MessageCommentNavigation.open(
            uri: message?.uri,
            nativeURI: message?.nativeUri,
            payload: MessageCommentAnchorPayload(
                uri: message?.uri,
                nativeURI: message?.nativeUri,
                subjectID: message?.subjectId,
                rootID: message?.rootId,
                sourceID: message?.sourceId,
                targetID: message?.targetId,
                businessID: message?.businessId,
                business: message?.business,
                source: "mention"
            ),
            coordinator: coordinator, context: linkContext
        )
    }
}

// MARK: - Like List

private struct LikeListView: View {
    @Environment(\.contentLinkContext) private var linkContext
    let viewModel: MessageCenterViewModel
    let coordinator: AppCoordinator

    var body: some View {
        MessageNotificationScrollView(
            page: viewModel.likePage,
            emptyTitle: "No Likes",
            emptyIcon: "heart",
            refresh: { await viewModel.refreshLikes() },
            loadMore: { await viewModel.loadMoreLikes() },
            retry: { failure in
                if let failure { await viewModel.retryLikes(failure) } else { await viewModel.loadLikes() }
            },
            row: { item in
                likeRow(item).onTapGesture { navigateToSource(item) }
            }
        )
        .task(id: AccountManager.shared.identityRevision) { await viewModel.loadLikes() }
    }

    private func likeRow(_ item: LikeMessageResult.LikeMsgItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            let firstUser = item.users?.first
            AvatarImage(urlString: firstUser?.avatarURL ?? "", size: 42)
                .onTapGesture {
                    if let mid = firstUser?.mid {
                        coordinator.navigate(to: .userSpace(mid))
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    likeUserNames(item)
                    Spacer()
                    if let t = item.likeTime {
                        Text(FormatUtils.timeAgo(from: t))
                            .appFont(.messageMeta)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text("liked your \(item.item?.business ?? String(localized: "content"))")
                    .appFont(.messageBody)
                    .foregroundStyle(.secondary)

                if let title = item.item?.title ?? item.item?.desc, !title.isEmpty {
                    MessageNotificationQuote(title: title)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .messageRowDivider(inset: 54)
    }

    private func likeUserNames(_ item: LikeMessageResult.LikeMsgItem) -> some View {
        let names = (item.users ?? []).prefix(3).map { $0.displayName }
        let extra = (item.counts ?? 0) - names.count
        let text = names.joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
        return Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
    }

    private func navigateToSource(_ item: LikeMessageResult.LikeMsgItem) {
        let message = item.item
        MessageCommentNavigation.open(
            uri: message?.uri,
            nativeURI: message?.nativeUri,
            payload: MessageCommentAnchorPayload(
                uri: message?.uri,
                nativeURI: message?.nativeUri,
                business: message?.business,
                source: "like"
            ),
            coordinator: coordinator, context: linkContext
        )
    }
}

// MARK: - System List

private struct SystemListView: View {
    @Environment(\.contentLinkContext) private var linkContext
    let viewModel: MessageCenterViewModel
    let coordinator: AppCoordinator

    var body: some View {
        MessageNotificationScrollView(
            page: viewModel.systemPage,
            emptyTitle: "No Notifications",
            emptyIcon: "bell.slash",
            refresh: { await viewModel.refreshSystem() },
            loadMore: { await viewModel.loadMoreSystem() },
            retry: { failure in
                if let failure { await viewModel.retrySystem(failure) } else { await viewModel.loadSystem() }
            },
            row: { item in
                systemRow(item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = item.actionURL {
                            coordinator.handle(url: url, context: linkContext)
                        }
                    }
            }
        )
        .task(id: AccountManager.shared.identityRevision) { await viewModel.loadSystem() }
    }

    private func systemRow(_ item: SystemNotifyResult.SystemNotifyItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let avatar = item.avatarURL {
                AvatarImage(urlString: avatar, size: 42)
            } else {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: "bell.badge.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.displayTitle)
                        .appFont(.messageTitle)
                        .fontWeight(.semibold)
                    Spacer()
                    if let timeText = item.timestampText {
                        Text(timeText)
                            .appFont(.messageMeta)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !item.displayContent.isEmpty {
                    Text(item.displayContent)
                        .appFont(.messageBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }

                if item.actionURL != nil {
                    HStack(spacing: AppSpacing.xs) {
                        Text(item.linkLabel ?? String(localized: "View Details"))
                        Image(systemName: "chevron.right")
                    }
                    .appFont(.messageMeta)
                    .foregroundStyle(Color.biliAccent)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .messageRowDivider(inset: 54)
    }
}

private struct MessageNotificationScrollView<Item: Identifiable, Row: View>: View {
    let page: MessageCenterViewModel.PageSnapshot<Item>
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let refresh: @MainActor () async -> Void
    let loadMore: @MainActor () async -> Void
    let retry: @MainActor (MessageCenterViewModel.PageFailure?) async -> Void
    @ViewBuilder let row: (Item) -> Row

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(page.items) { item in
                    row(item)
                        .onAppear {
                            if item.id == page.items.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
                if !page.items.isEmpty {
                    MessagePageFooter(
                        isLoading: page.isLoading && !page.isRefreshing,
                        failure: page.failure,
                        hasMore: page.hasMore,
                        loadMore: { Task { await loadMore() } },
                        retry: { pageFailure in Task { await retry(pageFailure) } }
                    )
                }
            }
            .padding(.horizontal, sizeClass == .regular ? AppSpacing.xl : AppSpacing.l)
            .padding(.vertical, AppSpacing.m)
            .frame(maxWidth: ReadableWidth.feed)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refresh() }
        .overlay {
            if page.items.isEmpty && (page.isLoading || !page.attempted) {
                ProgressView()
            } else if page.items.isEmpty, !page.loaded {
                MessageLoadFailureView(message: page.failure?.message) {
                    Task { await retry(page.failure) }
                }
            } else if page.items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            }
        }
    }
}

private struct MessageNotificationQuote: View {
    let title: String

    var body: some View {
        Text(title)
            .appFont(.messageMeta)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppFill.nested,
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
    }
}

private extension View {
    func messageRowDivider(inset: CGFloat) -> some View {
        overlay(alignment: .bottom) {
            Divider()
                .opacity(0.35)
                .padding(.leading, inset)
        }
    }
}

struct MessageLoadFailureView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Load Failed", systemImage: "exclamationmark.triangle")
        } description: {
            if let message { Text(message) }
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
        }
    }
}

private struct MessagePageFooter: View {
    let isLoading: Bool
    let failure: MessageCenterViewModel.PageFailure?
    let hasMore: Bool
    let loadMore: () -> Void
    let retry: (MessageCenterViewModel.PageFailure) -> Void

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 44)
        } else if let failure {
            VStack(spacing: 8) {
                Label("Load Failed", systemImage: "exclamationmark.triangle")
                    .appFont(.messageTitle)
                Text(failure.message)
                    .appFont(.messageMeta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { retry(failure) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if hasMore {
            Button("More", action: loadMore)
                .frame(minHeight: 44)
        }
    }
}
