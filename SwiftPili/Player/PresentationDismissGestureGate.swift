import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

struct PresentationDismissGestureGate: UIViewRepresentable {
    enum Policy: Equatable {
        case playerTouch
        case videoDetailBrowsing
    }

    let isHeld: Bool
    var policy: Policy = .playerTouch

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.setHeld(isHeld, policy: policy)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.setHeld(false, policy: view.policy)
    }

    @MainActor
    final class ProbeView: UIView {
        fileprivate private(set) var policy: Policy = .playerTouch
        private let owner = UUID()
        private var isHeld = false
        private var retryBudget = 0
        private var retryScheduled = false
        private var attachmentRevision = 0
        private weak var observedTransition: (any UIViewControllerTransitionCoordinator)?
        #if DEBUG
        private var diagnosticFacts: Set<String> = []
        private static let logger = Logger(subsystem: "com.swiftpili.app", category: "DetailDismiss")
        #endif

        func setHeld(_ held: Bool, policy: Policy) {
            let changed = isHeld != held || self.policy != policy
            self.policy = policy
            isHeld = held
            if changed { retryBudget = held ? 3 : 0 }
            reconcile()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachmentChanged()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachmentChanged()
        }

        private func attachmentChanged() {
            attachmentRevision += 1
            retryScheduled = false
            observedTransition = nil
            DismissGestureHolds.release(owner: owner)
            retryBudget = isHeld && window != nil ? 3 : 0
            reconcile()
        }

        private func reconcile() {
            guard isHeld, window != nil, superview != nil else {
                DismissGestureHolds.release(owner: owner)
                return
            }
            let candidates = dismissRecognizers()
            let navigation = nearestController?.navigationController
                ?? nearestController as? UINavigationController
            let edge = navigation?.interactivePopGestureRecognizer
            let selected: [UIGestureRecognizer]
            switch policy {
            case .playerTouch:
                selected = candidates
            case .videoDetailBrowsing:
                selected = browsingRecognizers(candidates, preserving: edge)
            }
            DismissGestureHolds.reconcile(
                owner: owner, recognizers: selected,
                cancelsActiveGesture: policy == .playerTouch
            )
            recordDiagnostics(candidates, selected: selected, navigation: navigation)
            observeNativeSettlement()
            scheduleAttachmentRetry()
        }

        private func browsingRecognizers(
            _ candidates: [UIGestureRecognizer], preserving edge: UIGestureRecognizer?
        ) -> [UIGestureRecognizer] {
            var groups: [ObjectIdentifier: [UIGestureRecognizer]] = [:]
            for recognizer in candidates {
                guard let view = recognizer.view else { continue }
                groups[ObjectIdentifier(view), default: []].append(recognizer)
            }
            return groups.values.flatMap { group in
                let hasPublicEdge = group.contains { isLiveLeadingEdge($0, navigationEdge: edge) }
                let contentCandidates = group.filter {
                    $0 !== edge && !($0 is UIScreenEdgePanGestureRecognizer) && !isScrollRecognizer($0)
                }
                let hasContentPan = contentCandidates.contains { $0 is UIPanGestureRecognizer }
                let acceptsUnknown = hasPublicEdge && hasContentPan
                return contentCandidates.filter {
                    if $0 is UIPinchGestureRecognizer { return true }
                    return hasPublicEdge && ($0 is UIPanGestureRecognizer || acceptsUnknown)
                }
            }
        }

        private func isLiveLeadingEdge(
            _ recognizer: UIGestureRecognizer, navigationEdge: UIGestureRecognizer?
        ) -> Bool {
            guard recognizer.isEnabled,
                  let edgePan = recognizer as? UIScreenEdgePanGestureRecognizer,
                  edgePan === navigationEdge || recognizer.delegate != nil
            else { return false }
            let leading: UIRectEdge = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            return edgePan.edges.contains(leading)
        }

        private var nearestController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        private func dismissRecognizers() -> [UIGestureRecognizer] {
            var found: [UIGestureRecognizer] = []
            var current = superview
            while let candidate = current {
                for recognizer in candidate.gestureRecognizers ?? [] {
                    guard let delegate = recognizer.delegate,
                          String(describing: type(of: delegate)).hasSuffix("DismissSubInteraction")
                    else { continue }
                    found.append(recognizer)
                }
                current = candidate.superview
            }
            return found
        }

        private func isScrollRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = recognizer.view as? UIScrollView else { return false }
            return recognizer === scroll.panGestureRecognizer || recognizer === scroll.pinchGestureRecognizer
        }

        private func scheduleAttachmentRetry() {
            guard retryBudget > 0, !retryScheduled else { return }
            retryBudget -= 1
            retryScheduled = true
            let revision = attachmentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attachmentRevision == revision else { return }
                self.retryScheduled = false
                self.reconcile()
            }
        }

        private func observeNativeSettlement() {
            guard let transition = nearestController?.transitionCoordinator else { return }
            guard observedTransition !== transition else { return }
            observedTransition = transition
            let revision = attachmentRevision
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.attachmentRevision == revision else { return }
                self.retryBudget = max(self.retryBudget, 1)
                self.scheduleAttachmentRetry()
            }
        }

        private func recordDiagnostics(
            _ candidates: [UIGestureRecognizer], selected: [UIGestureRecognizer],
            navigation: UINavigationController?
        ) {
            #if DEBUG
            guard policy == .videoDetailBrowsing, diagnosticFacts.count < 48 else { return }
            var records = candidates.map { recognizer in
                let content: UIGestureRecognizer?
                if #available(iOS 26.0, *) {
                    content = navigation?.interactiveContentPopGestureRecognizer
                } else {
                    content = nil
                }
                return "id=\(ObjectIdentifier(recognizer)) class=\(type(of: recognizer)) "
                    + "delegate=\(recognizer.delegate.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "view=\(recognizer.view.map { "\(type(of: $0)):\(ObjectIdentifier($0))" } ?? "nil") "
                    + "pan=\(recognizer is UIPanGestureRecognizer) pinch=\(recognizer is UIPinchGestureRecognizer) "
                    + "edgeType=\(recognizer is UIScreenEdgePanGestureRecognizer) "
                    + "navEdge=\(recognizer === navigation?.interactivePopGestureRecognizer) "
                    + "navContent=\(recognizer === content) scroll=\(isScrollRecognizer(recognizer)) "
                    + "selected=\(selected.contains { $0 === recognizer }) enabled=\(recognizer.isEnabled) "
                    + "state=\(recognizer.state.rawValue) holds=\(DismissGestureHolds.count(for: recognizer))"
            }
            if records.isEmpty { records = ["no Zoom dismissal candidates on own ancestor chain"] }
            for record in records where diagnosticFacts.insert(record).inserted {
                let context = "owner=\(owner.uuidString) os=\(UIDevice.current.systemVersion) "
                    + "window=\(String(describing: window?.bounds))"
                Self.logger.notice("\(context, privacy: .public) \(record, privacy: .public)")
            }
            #endif
        }
    }
}

extension View {
    func preventsVideoDetailContentDismissal(isActive: Bool) -> some View {
        background(PresentationDismissGestureGate(isHeld: isActive, policy: .videoDetailBrowsing))
    }
}

@MainActor
private enum DismissGestureHolds {
    @MainActor
    private final class Entry {
        weak var recognizer: UIGestureRecognizer?
        let originallyEnabled: Bool
        var owners: Set<UUID> = []

        init(_ recognizer: UIGestureRecognizer) {
            self.recognizer = recognizer
            originallyEnabled = recognizer.isEnabled
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func reconcile(owner: UUID, recognizers: [UIGestureRecognizer], cancelsActiveGesture: Bool) {
        entries = entries.filter { $0.value.recognizer != nil }
        let desired = Set(recognizers.map(ObjectIdentifier.init))
        release(owner: owner, excluding: desired)
        for recognizer in recognizers {
            let identity = ObjectIdentifier(recognizer)
            let existing = entries[identity]
            let entry = existing?.recognizer === recognizer ? existing : nil
            let isRecognizing = recognizer.state == .began || recognizer.state == .changed
            guard cancelsActiveGesture || !isRecognizing else { continue }
            let held = entry ?? Entry(recognizer)
            held.owners.insert(owner)
            entries[identity] = held
            if recognizer.isEnabled { recognizer.isEnabled = false }
        }
    }

    static func release(owner: UUID, excluding desired: Set<ObjectIdentifier> = []) {
        for (identity, entry) in entries where !desired.contains(identity) {
            entry.owners.remove(owner)
            guard entry.owners.isEmpty else { continue }
            entry.recognizer?.isEnabled = entry.originallyEnabled
            entries.removeValue(forKey: identity)
        }
    }

    static func count(for recognizer: UIGestureRecognizer) -> Int {
        let entry = entries[ObjectIdentifier(recognizer)]
        return entry?.recognizer === recognizer ? entry?.owners.count ?? 0 : 0
    }
}
