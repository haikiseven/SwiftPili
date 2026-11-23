import SwiftUI

struct ChatView: View {
    let talkerId: Int
    let name: String
    let face: String?

    @Environment(\.authManager) private var authManager
    @Environment(\.accountManager) private var accountManager

    init(talkerId: Int, name: String, face: String?) {
        self.talkerId = talkerId
        self.name = name
        self.face = face
    }

    var body: some View {
        ChatConversationView(
            talkerId: talkerId,
            name: name,
            face: face,
            authManager: authManager,
            accountManager: accountManager
        )
        .id(talkerId)
    }
}

private struct ChatConversationView: View {
    @AppMotion private var motion
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ChatViewModel
    let name: String
    let face: String?

    init(
        talkerId: Int,
        name: String,
        face: String?,
        authManager: AuthManager,
        accountManager: AccountManager
    ) {
        self.name = name
        self.face = face
        _viewModel = State(
            initialValue: ChatViewModel(
                talkerId: talkerId,
                authManager: authManager,
                accountManager: accountManager
            )
        )
    }

    private var bubbleMaxWidth: CGFloat { sizeClass == .regular ? 420 : 260 }

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if !viewModel.messages.isEmpty {
                            historyFeedback
                        }
                        if viewModel.hasMore {
                            Button(action: viewModel.loadOlder) {
                                if viewModel.isLoadingOlder {
                                    ProgressView()
                                } else {
                                    Text("Load earlier messages")
                                        .appFont(.messageMeta)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44)
                            .disabled(viewModel.isReading)
                        }
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, msg in
                            ChatMessageRow(
                                message: msg,
                                previous: index > 0 ? viewModel.messages[index - 1] : nil,
                                talkerID: viewModel.talkerId, face: face, myUID: viewModel.myUID,
                                bubbleMaxWidth: bubbleMaxWidth
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: ReadableWidth.feed)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: viewModel.scrollTargetID) { _, targetID in
                    if let targetID {
                        withAnimation(motion.animation(normal: .easeOut(duration: 0.2))) {
                            proxy.scrollTo(targetID, anchor: .bottom)
                        }
                    }
                }
            }
            .overlay {
                if !viewModel.isAuthenticated {
                    ContentUnavailableView(
                        "Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if viewModel.messages.isEmpty {
                    if viewModel.loadedOnce && viewModel.historyFailure == nil {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Say hi to start the conversation.")
                        )
                    } else {
                        historyFeedback
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposerView(sendMessage: viewModel.sendMessage)
                .disabled(!viewModel.isAuthenticated)
        }
        .appAmbientBrowseBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.navigate(to: .userSpace(viewModel.talkerId))
                } label: {
                    ChatAvatarView(face: face, size: 30)
                }
                .accessibilityLabel(Text(String(format: String(localized: "Open %@'s profile"), name)))
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await viewModel.runWhileVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stopVisibleRun() }
        }
        .onDisappear { viewModel.stopVisibleRun() }
    }

    @ViewBuilder private var historyFeedback: some View {
        if !viewModel.loadedOnce {
            if viewModel.isReading || !viewModel.initialAttempted {
                ProgressView()
            } else {
                MessageLoadFailureView(message: viewModel.initialFailure, retry: viewModel.retryInitial)
            }
        } else if let failure = viewModel.historyFailure {
            MessageLoadFailureView(message: failure, retry: viewModel.retryHistory)
        }
    }
}
