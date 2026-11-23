import SwiftUI

private struct ContentLinkContextKey: EnvironmentKey {
    static let defaultValue: ContentLinkContext? = nil
}

private struct ContentLinkHandoffKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var contentLinkContext: ContentLinkContext? {
        get { self[ContentLinkContextKey.self] }
        set { self[ContentLinkContextKey.self] = newValue }
    }
    var contentLinkDefersToParent: Bool {
        get { self[ContentLinkHandoffKey.self] }
        set { self[ContentLinkHandoffKey.self] = newValue }
    }
}

extension View {
    func contentLinks(
        presentsFeedback: Bool = true,
        handlesURLs: Bool = true,
        isCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        beforeNavigate: @escaping @MainActor @Sendable () -> Void = {}
    ) -> some View {
        modifier(ContentLinkScope(presentsFeedback: presentsFeedback, handlesURLs: handlesURLs,
                                  isCurrent: isCurrent, beforeNavigate: beforeNavigate))
    }

    func contentLinkFeedback(
        controller: ContentLinkController,
        scopeID: UUID,
        isEnabled: Bool = true,
        bottomPadding: CGFloat = 0
    ) -> some View {
        modifier(ContentLinkFeedbackModifier(
            controller: controller,
            scopeID: scopeID,
            isEnabled: isEnabled,
            bottomPadding: bottomPadding
        ))
    }
}

private struct ContentLinkScope: ViewModifier {
    let presentsFeedback: Bool
    let handlesURLs: Bool
    let isCurrent: @MainActor @Sendable () -> Bool
    let beforeNavigate: @MainActor @Sendable () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.contentLinkContext) private var parentContext
    @Environment(\.openURL) private var upstream
    @Environment(\.contentLinkDefersToParent) private var defersToParent
    @State private var lifetime = ContentLinkLifetime()

    func body(content: Content) -> some View {
        let own = lifetime.capture().guarded(by: isCurrent).preparingNavigation(beforeNavigate)
        let origin = parentContext?.joining(own, presentsFeedback: presentsFeedback) ?? own
        content
            .environment(\.contentLinkContext, origin)
            .environment(\.openURL, OpenURLAction { url in
                if handlesURLs, !defersToParent, BiliURLParser.handlesContent(url) {
                    return coordinator.openContentURL(url, context: origin)
                }
                coordinator.contentLinks.cancel()
                guard origin.isCurrent() else { return .discarded }
                upstream(url)
                return .handled
            })
            .contentLinkFeedback(
                controller: coordinator.contentLinks,
                scopeID: origin.presentationID,
                isEnabled: presentsFeedback
            )
            .onAppear { lifetime.activate() }
            .onDisappear {
                lifetime.deactivate()
                coordinator.contentLinks.cancel(lifetimeID: lifetime.id)
            }
    }
}

private struct ContentLinkFeedbackModifier: ViewModifier {
    let controller: ContentLinkController
    let scopeID: UUID
    let isEnabled: Bool
    let bottomPadding: CGFloat
    @AppMotion private var motion

    private var scopedPresentation: ContentLinkController.Presentation? {
        guard isEnabled,
              let state = controller.presentation,
              state.scopeID == scopeID else { return nil }
        return state
    }

    private var loadingPresentation: ContentLinkController.Presentation? {
        guard let state = scopedPresentation, case .loading = state.status else { return nil }
        return state
    }

    private var alertPresentation: ContentLinkController.Presentation? {
        guard let state = scopedPresentation else { return nil }
        switch state.status {
        case .loading: return nil
        case .failed, .unsupported: return state
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertPresentation != nil },
            set: { presented in
                if !presented, let state = alertPresentation {
                    controller.cancel(requestID: state.id)
                }
            }
        )
    }

    private var alertTitle: LocalizedStringKey {
        guard let state = alertPresentation else { return "Link Unavailable" }
        switch state.status {
        case .failed: return "Unable to Open Link"
        case .unsupported, .loading: return "Link Unavailable"
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .overlay(alignment: .bottom) {
                    Group {
                        if let state = loadingPresentation {
                            ContentLinkLoadingCapsule {
                                controller.cancel(requestID: state.id)
                            }
                            .padding(.horizontal, AppSpacing.l)
                            .padding(.bottom, AppSpacing.m + bottomPadding)
                            .transition(motion.transition(
                                normal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(
                        motion.feedbackAnimation(normal: .spring(duration: 0.25)),
                        value: loadingPresentation?.id
                    )
                }
                .alert(alertTitle, isPresented: alertPresented, presenting: alertPresentation) { state in
                    if case .failed = state.status {
                        Button("Retry") { controller.retry(state.id) }
                    }
                    if BiliLinkHostPolicy.isSupportedScheme(state.pageURL.scheme) {
                        Button("Open Original Page") { controller.openPage(state.id) }
                    }
                    Button("Cancel", role: .cancel) {
                        controller.cancel(requestID: state.id)
                    }
                } message: { state in
                    switch state.status {
                    case .failed(let message):
                        Text(message)
                    case .unsupported:
                        Text("This link cannot be opened in SwiftPili.")
                    case .loading:
                        EmptyView()
                    }
                }
        } else {
            content
        }
    }
}

private struct ContentLinkLoadingCapsule: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Opening Link")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}
