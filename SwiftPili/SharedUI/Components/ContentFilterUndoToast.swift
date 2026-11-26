import Observation
import SwiftUI
import UIKit

// MARK: - 4-Second Undo Capsule Toast State Center

@MainActor
@Observable
final class ContentFilterUndoToastCenter {
    struct ToastItem: Identifiable, Equatable, Sendable {
        let id: UUID
        let message: String
        let undoLabel: String
        let systemImage: String

        init(
            id: UUID = UUID(),
            message: String,
            undoLabel: String = String(localized: "Undo"),
            systemImage: String = "eye.slash"
        ) {
            self.id = id
            // Never allow middle-dot separators in toast copy.
            self.message = message.replacingOccurrences(of: "\u{00B7}", with: " ")
            self.undoLabel = undoLabel.replacingOccurrences(of: "\u{00B7}", with: " ")
            self.systemImage = systemImage
        }
    }

    static let shared = ContentFilterUndoToastCenter()
    static let defaultDuration: Duration = .seconds(4)

    private(set) var currentToast: ToastItem?
    private(set) var activeHostID: UUID?

    @ObservationIgnored private var undoHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var hosts: [WeakUndoToastHost] = []

    init() {}

    @discardableResult
    func show(
        message: String,
        undoLabel: String = String(localized: "Undo"),
        systemImage: String = "eye.slash",
        duration: Duration = ContentFilterUndoToastCenter.defaultDuration,
        onUndo: @escaping @MainActor () -> Void
    ) -> ToastItem {
        dismissTask?.cancel()
        let item = ToastItem(
            message: message,
            undoLabel: undoLabel,
            systemImage: systemImage
        )
        currentToast = item
        undoHandler = onUndo
        activeHostID = resolveActiveHostID()

        let toastID = item.id
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.currentToast?.id == toastID else { return }
            self.clearCurrent()
        }
        return item
    }

    func performUndo() {
        guard currentToast != nil else { return }
        let handler = undoHandler
        clearCurrent()
        handler?()
    }

    func dismiss(id: UUID? = nil) {
        guard let current = currentToast else { return }
        if let id, current.id != id { return }
        clearCurrent()
    }

    private func clearCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
        undoHandler = nil
        currentToast = nil
        activeHostID = nil
    }

    fileprivate func registerHost(_ id: UUID, view: UIView) {
        hosts.removeAll { $0.view == nil || $0.id == id }
        hosts.append(WeakUndoToastHost(id: id, view: view))
        if currentToast != nil, activeHostID == nil {
            Task { @MainActor [weak self] in
                guard let self, self.currentToast != nil, self.activeHostID == nil else { return }
                self.activeHostID = self.resolveActiveHostID()
            }
        }
    }

    fileprivate func unregisterHost(_ id: UUID) {
        hosts.removeAll { $0.view == nil || $0.id == id }
        if activeHostID == id {
            Task { @MainActor [weak self] in
                guard let self, self.activeHostID == id else { return }
                self.activeHostID = self.resolveActiveHostID()
            }
        }
    }

    private func resolveActiveHostID() -> UUID? {
        hosts.removeAll { $0.view == nil }
        let reversed = hosts.reversed()
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController && $0.isKeyWindow }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController && $0.isForegroundActive }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isOnTopController }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible && $0.isKeyWindow }) {
            return match.id
        }
        if let match = reversed.first(where: { $0.isEligible }) {
            return match.id
        }
        return hosts.last?.id
    }
}

// MARK: - Weak UIKit Host Probe

@MainActor
private final class WeakUndoToastHost {
    let id: UUID
    weak var view: UIView?

    init(id: UUID, view: UIView) {
        self.id = id
        self.view = view
    }

    var isEligible: Bool {
        guard let view, let window = view.window else { return false }
        guard !window.isHidden, window.alpha > 0.01 else { return false }
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha <= 0.01 { return false }
            current = node.superview
        }
        return true
    }

    var isKeyWindow: Bool {
        view?.window?.isKeyWindow == true
    }

    var isForegroundActive: Bool {
        view?.window?.windowScene?.activationState == .foregroundActive
    }

    var isOnTopController: Bool {
        var responder: UIResponder? = view?.next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.presentedViewController == nil
            }
            responder = current.next
        }
        return false
    }
}

private struct UndoToastHostProbe: UIViewRepresentable {
    let onAttach: @MainActor (UIView) -> Void
    let onDetach: @MainActor () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onAttach = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        let onDetach = uiView.onDetach
        uiView.onAttach = nil
        uiView.onDetach = nil
        onDetach?()
    }

    @MainActor
    final class ProbeView: UIView {
        var onAttach: (@MainActor (UIView) -> Void)?
        var onDetach: (@MainActor () -> Void)?

        override var intrinsicContentSize: CGSize { .zero }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttach?(self)
            } else {
                onDetach?()
            }
        }
    }
}

// MARK: - Capsule Toast View

struct ContentFilterUndoToastView: View {
    let toast: ContentFilterUndoToastCenter.ToastItem
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @AppMotion private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onUndo()
            } label: {
                Text(toast.undoLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.biliAccent.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(toast.undoLabel))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .undoToastCapsuleSurface(reduceTransparency: reduceTransparency)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height > 18 {
                        onDismiss()
                    }
                }
        )
        .transition(motion.transition(normal: .move(edge: .bottom).combined(with: .opacity)))
    }
}

private extension View {
    @ViewBuilder
    func undoToastCapsuleSurface(reduceTransparency: Bool) -> some View {
        if !reduceTransparency, #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
    }
}

// MARK: - Overlay Modifier

private struct ContentFilterUndoToastOverlayModifier: ViewModifier {
    let bottomPadding: CGFloat
    @State private var hostID = UUID()
    @AppMotion private var motion

    private var center: ContentFilterUndoToastCenter { ContentFilterUndoToastCenter.shared }

    private var visibleToast: ContentFilterUndoToastCenter.ToastItem? {
        guard let toast = center.currentToast else { return nil }
        if let activeID = center.activeHostID {
            return activeID == hostID ? toast : nil
        }
        return toast
    }

    func body(content: Content) -> some View {
        let toast = visibleToast
        content
            .background {
                UndoToastHostProbe(
                    onAttach: { center.registerHost(hostID, view: $0) },
                    onDetach: { center.unregisterHost(hostID) }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if let toast {
                        ContentFilterUndoToastView(
                            toast: toast,
                            onUndo: { center.performUndo() },
                            onDismiss: { center.dismiss(id: toast.id) }
                        )
                        .padding(.horizontal, AppSpacing.l)
                        .padding(.bottom, bottomPadding)
                    }
                }
                .animation(motion.feedbackAnimation(normal: .spring(duration: 0.28)), value: toast)
            }
    }
}

extension View {
    func contentFilterUndoToastOverlay(bottomPadding: CGFloat = 16) -> some View {
        modifier(ContentFilterUndoToastOverlayModifier(bottomPadding: bottomPadding))
    }
}

// MARK: - Shared Video Card Context Menu Builder (UIKit Home & Search Cards)

struct VideoCardContextMenuTarget: Sendable {
    let aid: Int?
    let bvid: String?
    let title: String
    let ownerMid: Int?
    let ownerName: String
    let ownerFace: String?
}

@MainActor
enum VideoCardContextMenuBuilder {
    static func configuration(for target: VideoCardContextMenuTarget) -> UIContextMenuConfiguration? {
        let hasVideoID = (target.aid.map { $0 > 0 } ?? false)
            || (LocalContentFilterStore.normalizedBVID(target.bvid) != nil)
        let hasOwnerMID = (target.ownerMid ?? 0) > 0
        guard hasVideoID || hasOwnerMID else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIAction] = []

            if AuthManager.shared.isLoggedIn, hasVideoID {
                let dislikeAction = UIAction(
                    title: String(localized: "Not Interested"),
                    image: UIImage(systemName: "hand.thumbsdown")
                ) { _ in
                    Self.performCloudDislike(target)
                }
                actions.append(dislikeAction)
            }

            if hasVideoID {
                let hideVideoAction = UIAction(
                    title: String(localized: "Locally Hide This Video"),
                    image: UIImage(systemName: "eye.slash")
                ) { _ in
                    Self.performLocalHideVideo(target)
                }
                actions.append(hideVideoAction)
            }

            if let mid = target.ownerMid, mid > 0 {
                let displayName = target.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "UID \(mid)"
                    : target.ownerName
                let blockUPAction = UIAction(
                    title: String(format: String(localized: "Locally Block UP: %@"), displayName),
                    image: UIImage(systemName: "person.slash"),
                    attributes: .destructive
                ) { _ in
                    Self.performLocalBlockUP(mid: mid, name: displayName, face: target.ownerFace)
                }
                actions.append(blockUPAction)
            }

            return UIMenu(title: "", children: actions)
        }
    }

    static func performCloudDislike(_ target: VideoCardContextMenuTarget) {
        let store = LocalContentFilterStore.shared
        store.markSessionDisliked(aid: target.aid, bvid: target.bvid)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let aid = target.aid
        let bvid = target.bvid
        Task {
            do {
                try await VideoAPI.dislikeArchive(aid: aid, bvid: bvid, dislike: true)
            } catch {
                if !BiliAPIRetryPolicy.isCancellation(error) {
                    PlayerLog.log("[ContentFilter] cloud dislike failed: \(error)")
                }
            }
        }

        ContentFilterUndoToastCenter.shared.show(
            message: String(localized: "Marked as not interested"),
            systemImage: "hand.thumbsdown"
        ) {
            store.unmarkSessionDisliked(aid: aid, bvid: bvid)
            Task {
                _ = try? await VideoAPI.dislikeArchive(aid: aid, bvid: bvid, dislike: false)
            }
        }
    }

    static func performLocalHideVideo(_ target: VideoCardContextMenuTarget) {
        let store = LocalContentFilterStore.shared
        let added = store.blockVideo(
            aid: target.aid,
            bvid: target.bvid,
            title: target.title,
            ownerName: target.ownerName
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let aid = target.aid
        let bvid = target.bvid
        ContentFilterUndoToastCenter.shared.show(
            message: String(localized: "Hidden video locally"),
            systemImage: "eye.slash"
        ) {
            if let added {
                store.unblockVideo(id: added.id)
            } else {
                store.unblockVideo(aid: aid, bvid: bvid)
            }
        }
    }

    static func performLocalBlockUP(mid: Int, name: String, face: String?) {
        let store = LocalContentFilterStore.shared
        _ = store.blockUP(mid: mid, name: name, face: face)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        ContentFilterUndoToastCenter.shared.show(
            message: String(format: String(localized: "Locally blocked UP \"%@\""), name),
            systemImage: "person.slash"
        ) {
            store.unblockUP(mid: mid)
        }
    }
}
