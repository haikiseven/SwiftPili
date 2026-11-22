import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class CommentComposerFocus {
    private(set) var requestToken: UInt64 = 0
    private(set) var dismissToken: UInt64 = 0
    @ObservationIgnored private weak var activeHostView: UIView?

    func request() {
        requestToken &+= 1
    }

    func dismiss() {
        dismissToken &+= 1
        scheduleMainRunloopTurn { [weak view = activeHostView] in
            view?.endEditing(true)
        }
    }

    func attachHostView(_ view: UIView) {
        activeHostView = view
    }

    func detachHostView(_ view: UIView) {
        if activeHostView === view { activeHostView = nil }
    }
}

@MainActor
@Observable
final class CommentComposerPresentation {
    var isExpanded = false
}

struct ComposerWindowAttachmentProbe: UIViewRepresentable {
    let onAttach: @MainActor (UIView) -> Void
    let onDetach: @MainActor (UIView) -> Void

    func makeUIView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onAttach = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateUIView(_ uiView: WindowProbeView, context: Context) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
    }

    static func dismantleUIView(_ uiView: WindowProbeView, coordinator: ()) {
        let onDetach = uiView.onDetach
        uiView.onAttach = nil
        uiView.onDetach = nil
        onDetach?(uiView)
    }

    @MainActor
    final class WindowProbeView: UIView {
        var onAttach: (@MainActor (UIView) -> Void)?
        var onDetach: (@MainActor (UIView) -> Void)?

        override var intrinsicContentSize: CGSize { .zero }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttach?(self)
            } else {
                onDetach?(self)
            }
        }
    }
}

struct CollapsibleComposer: View {
    @AppMotion private var motion
    @Binding var text: String
    @Binding var pictures: [ComposedPicture]
    var placeholder: String
    var replyBanner: String?
    var isSending = false
    var sendError: String?
    var focus: CommentComposerFocus
    var onCancelReply: (() -> Void)?
    var onSend: () -> Void
    var allowsCollapseAfterSend: () -> Bool = { true }
    var uploadScope: CommentComposerUploadScope?
    var isInteractionCurrent: () -> Bool = { true }

    var expansion: Binding<Bool>?
    var observedExpansion: Binding<Bool>?

    @State private var isLocallyExpanded = false

    private var usesExternalAuthority: Bool { expansion != nil }
    private var expansionBinding: Binding<Bool> { expansion ?? observedExpansion ?? $isLocallyExpanded }
    private var isExpanded: Bool { expansionBinding.wrappedValue }

    var body: some View {
        CommentComposerMorphContainer(
            isExpanded: isExpanded,
            hasDraft: hasDraft,
            sourceIdentity: uploadScope.map { AnyHashable($0.context.sourceIdentity) },
            onExpand: {
                guard isInteractionCurrent() else { return }
                expand()
            },
            expandedComposer: { composerBar }
        )
        .frame(maxWidth: ReadableWidth.feed)
        .frame(maxWidth: .infinity)
        .onChange(of: replyBanner) {
            guard !usesExternalAuthority, isInteractionCurrent() else { return }
            if replyBanner != nil {
                expand()
            } else {
                collapseIfNothingDrafted()
            }
        }
        .onChange(of: focus.requestToken) {
            guard !usesExternalAuthority, isInteractionCurrent(), !isExpanded else { return }
            openForFocusRequest()
        }
        .onChange(of: uploadScope?.context) {
            guard !usesExternalAuthority, isInteractionCurrent() else { return }
            if allowsCollapseAfterSend() { collapseIfNothingDrafted() }
        }
        .onChange(of: isSending) {
            guard !usesExternalAuthority, isInteractionCurrent() else { return }
            if !isSending, allowsCollapseAfterSend() { collapseIfNothingDrafted() }
        }
    }

    private var composerBar: some View {
        CommentComposerBar(
            text: $text,
            pictures: $pictures,
            placeholder: placeholder,
            replyBanner: replyBanner,
            isSending: isSending,
            sendError: sendError,
            focus: focus,
            autoFocusOnAppear: isExpanded && !isSending,
            usesExternalMorphSurface: true,
            onCancelReply: {
                guard isInteractionCurrent() else { return }
                onCancelReply?()
            },
            onCollapse: collapse,
            onSend: {
                guard isExpanded, isInteractionCurrent() else { return }
                onSend()
            },
            uploadScope: uploadScope,
            isInteractionCurrent: isInteractionCurrent
        )
        .id(uploadScope?.context.sourceIdentity)
        .id(AuthManager.shared.sessionGeneration)
    }

    static var composerPanelTransition: AnyTransition { .opacity }

    static var composerExpandAnimation: Animation { KeyboardAnimation.panelExpand }

    static var composerCollapseAnimation: Animation { KeyboardAnimation.panelCollapse }

    static var composerPanelAnimation: Animation { composerExpandAnimation }

    private func expand() {
        guard isInteractionCurrent(), uploadScope?.isCurrent() ?? true else { return }
        if !isExpanded {
            PlayerLog.log("[Composer] expanding from launcher (collapsible)")
            withAnimation(motion.animation(normal: Self.composerExpandAnimation)) {
                expansionBinding.wrappedValue = true
            }
        }
        focus.request()
    }

    private func openForFocusRequest() {
        guard isInteractionCurrent(), uploadScope?.isCurrent() ?? true, !isExpanded else { return }
        PlayerLog.log("[Composer] expanding for focus request (collapsible)")
        withAnimation(motion.animation(normal: Self.composerExpandAnimation)) {
            expansionBinding.wrappedValue = true
        }
    }

    private func collapse() {
        guard isInteractionCurrent(), isExpanded else { return }
        focus.dismiss()
        PlayerLog.log(
            "[Composer] collapsing to launcher (collapsible) draft=\(hasDraft ? 1 : 0)"
        )
        withAnimation(motion.animation(normal: Self.composerCollapseAnimation)) {
            expansionBinding.wrappedValue = false
        }
    }

    private func collapseIfNothingDrafted() {
        guard isInteractionCurrent(), !hasDraft else { return }
        if isExpanded {
            collapse()
        } else {
            focus.dismiss()
        }
    }

    private var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pictures.isEmpty
            || replyBanner != nil
    }
}
