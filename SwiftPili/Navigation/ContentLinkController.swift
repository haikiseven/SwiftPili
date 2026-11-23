import Foundation
import Observation

struct ContentLinkStateKey: Equatable, Hashable, Sendable {
    let presentationID: UUID
    let lifetimeIDs: Set<UUID>
    let revisions: [UUID: UInt64]
}

struct ContentLinkContext: Sendable {
    let presentationID: UUID
    let lifetimeIDs: Set<UUID>
    let revisions: [UUID: UInt64]
    let isCurrent: @MainActor @Sendable () -> Bool
    var beforeNavigate: @MainActor @Sendable () -> Void = {}

    var stateKey: ContentLinkStateKey {
        ContentLinkStateKey(
            presentationID: presentationID,
            lifetimeIDs: lifetimeIDs,
            revisions: revisions
        )
    }

    func preparingNavigation(_ action: @escaping @MainActor @Sendable () -> Void) -> ContentLinkContext {
        ContentLinkContext(
            presentationID: presentationID,
            lifetimeIDs: lifetimeIDs,
            revisions: revisions,
            isCurrent: isCurrent,
            beforeNavigate: action
        )
    }

    func guarded(by predicate: @escaping @MainActor @Sendable () -> Bool) -> ContentLinkContext {
        ContentLinkContext(
            presentationID: presentationID,
            lifetimeIDs: lifetimeIDs,
            revisions: revisions,
            isCurrent: { isCurrent() && predicate() },
            beforeNavigate: beforeNavigate
        )
    }

    func forwarded(
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        beforeNavigate: @escaping @MainActor @Sendable () -> Void
    ) -> ContentLinkContext {
        ContentLinkContext(
            presentationID: presentationID,
            lifetimeIDs: lifetimeIDs,
            revisions: revisions,
            isCurrent: isCurrent,
            beforeNavigate: beforeNavigate
        )
    }

    func joining(_ child: ContentLinkContext, presentsFeedback: Bool) -> ContentLinkContext {
        ContentLinkContext(
            presentationID: presentsFeedback ? child.presentationID : presentationID,
            lifetimeIDs: lifetimeIDs.union(child.lifetimeIDs),
            revisions: revisions.merging(child.revisions) { _, newer in newer },
            isCurrent: { isCurrent() && child.isCurrent() },
            beforeNavigate: {
                beforeNavigate()
                child.beforeNavigate()
            }
        )
    }
}

@MainActor
@Observable
final class ContentLinkLifetime {
    let id = UUID()
    private var revision: UInt64 = 0
    private var active = true

    func activate() { active = true }
    func invalidate() { revision &+= 1 }
    func deactivate() { active = false; invalidate() }

    func capture() -> ContentLinkContext {
        let captured = revision
        return ContentLinkContext(
            presentationID: id,
            lifetimeIDs: [id],
            revisions: [id: captured],
            isCurrent: { [weak self] in
                self?.active == true && self?.revision == captured
            }
        )
    }
}

@MainActor
@Observable
final class ContentLinkController {
    enum Status: Equatable {
        case loading
        case failed(String)
        case unsupported
    }

    struct Presentation: Identifiable, Equatable {
        let id: UUID
        let scopeID: UUID
        var status: Status
        var pageURL: URL
    }

    private struct Request {
        let id: UUID
        let url: URL
        let context: ContentLinkContext
        let present: @MainActor (Route) -> Void
    }

    private(set) var presentation: Presentation?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var task: Task<Void, Never>?

    func open(_ url: URL, context: ContentLinkContext, present: @escaping @MainActor (Route) -> Void) {
        cancel()
        guard !Task.isCancelled, context.isCurrent() else { return }
        let request = Request(id: UUID(), url: url, context: context, present: present)
        self.request = request
        if let result = BiliURLParser.localResult(url) {
            settle(result, request: request)
            return
        }
        presentation = Presentation(id: request.id, scopeID: context.presentationID, status: .loading, pageURL: url)
        task = Task { [weak self] in
            let result = await BiliURLParser.resolveInteractive(url)
            guard !Task.isCancelled else { return }
            self?.settle(result, request: request)
        }
    }

    func cancel(lifetimeID: UUID? = nil) {
        if let lifetimeID, request?.context.lifetimeIDs.contains(lifetimeID) != true { return }
        task?.cancel()
        task = nil
        request = nil
        presentation = nil
    }

    func retry(_ id: UUID) {
        guard let request, request.id == id else { return }
        guard request.context.isCurrent() else { cancel(); return }
        open(request.url, context: request.context, present: request.present)
    }

    func cancel(requestID: UUID) {
        guard request?.id == requestID else { return }
        cancel()
    }

    func openPage(_ id: UUID) {
        guard let request, request.id == id, request.context.isCurrent(),
              let page = presentation?.pageURL, BiliLinkHostPolicy.isSupportedScheme(page.scheme) else { return }
        complete(.inAppWeb(page), request: request)
    }

    private func settle(_ result: BiliURLParser.InteractiveResult, request: Request) {
        guard self.request?.id == request.id else { return }
        guard !Task.isCancelled, request.context.isCurrent() else { cancel(); return }
        task = nil
        switch result {
        case .native(let route):
            complete(route, request: request)
        case .unsupported(let url):
            presentation = Presentation(id: request.id, scopeID: request.context.presentationID,
                                        status: .unsupported, pageURL: url)
        case .failed(let message):
            presentation = Presentation(id: request.id, scopeID: request.context.presentationID,
                                        status: .failed(message), pageURL: request.url)
        case .cancelled:
            cancel()
        }
    }

    private func complete(_ route: Route, request: Request) {
        guard self.request?.id == request.id, request.context.isCurrent() else { return }
        self.request = nil
        presentation = nil
        task?.cancel()
        task = nil
        request.present(route)
    }
}
