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
            .overlay(alignment: .top) {
                if presentsFeedback {
                    ContentLinkFeedback(controller: coordinator.contentLinks, scopeID: origin.presentationID)
                }
            }
            .onAppear { lifetime.activate() }
            .onDisappear {
                lifetime.deactivate()
                coordinator.contentLinks.cancel(lifetimeID: lifetime.id)
            }
    }
}

struct ContentLinkFeedback: View {
    let controller: ContentLinkController
    let scopeID: UUID

    var body: some View {
        if let state = controller.presentation, state.scopeID == scopeID {
            VStack(alignment: .leading, spacing: 8) {
                switch state.status {
                case .loading:
                    HStack { ProgressView(); Text("Opening Link") }
                case .failed(let message):
                    Text(message).font(.callout)
                    Button("Retry") { controller.retry(state.id) }
                case .unsupported:
                    Text("Link Unavailable").font(.callout)
                }
                HStack {
                    if BiliLinkHostPolicy.isSupportedScheme(state.pageURL.scheme) {
                        Button("Open Original Page") { controller.openPage(state.id) }
                    }
                    Spacer()
                    Button("Cancel") { controller.cancel(requestID: state.id) }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card))
            .padding()
        }
    }
}
