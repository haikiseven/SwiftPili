import SwiftUI
import UIKit

/// Sheet sizing policy for iPad regular-width windows.
enum AppAdaptiveSheetSizing {
    case form
    case page
}

extension View {
    /// Applies compact detents + drag indicator on compact-width containers
    /// (iPhone and narrow iPad Split View), and native `.presentationSizing`
    /// on regular-width iPad windows so forms, keyboards, and pages are never
    /// clipped inside cramped `.medium` or fixed-height detents.
    func appAdaptiveSheet(
        compactDetents: Set<PresentationDetent> = [.medium, .large],
        padSizing: AppAdaptiveSheetSizing = .form,
        dragIndicator: Visibility = .visible
    ) -> some View {
        modifier(AppAdaptiveSheetModifier(
            compactDetents: compactDetents,
            padSizing: padSizing,
            dragIndicator: dragIndicator
        ))
    }
}

private struct AppAdaptiveSheetModifier: ViewModifier {
    let compactDetents: Set<PresentationDetent>
    let padSizing: AppAdaptiveSheetSizing
    let dragIndicator: Visibility

    /// Seeded synchronously from the hosting window before presentation so iPad
    /// receives `.presentationSizing` on frame 0 rather than inside `.sheet`'s
    /// overridden `.compact` environment.
    @State private var windowHorizontalSizeClass: UIUserInterfaceSizeClass =
        AppWindowMetrics.current?.traitCollection.horizontalSizeClass ?? .unspecified

    private var usesRegularPadSizing: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let effective = windowHorizontalSizeClass == .unspecified
            ? (AppWindowMetrics.current?.traitCollection.horizontalSizeClass ?? .unspecified)
            : windowHorizontalSizeClass
        return effective == .regular
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        sizedContent(content)
            .background {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    WindowHorizontalSizeClassProbe { sizeClass in
                        if windowHorizontalSizeClass != sizeClass {
                            windowHorizontalSizeClass = sizeClass
                        }
                    }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func sizedContent(_ content: Content) -> some View {
        if usesRegularPadSizing {
            if #available(iOS 18.0, *) {
                switch padSizing {
                case .form:
                    content.presentationSizing(.form)
                case .page:
                    content.presentationSizing(.page)
                }
            } else {
                content
            }
        } else {
            content
                .presentationDetents(compactDetents)
                .presentationDragIndicator(dragIndicator)
        }
    }
}

private struct WindowHorizontalSizeClassProbe: UIViewRepresentable {
    let onChange: (UIUserInterfaceSizeClass) -> Void

    func makeUIView(context _: Context) -> HorizontalSizeClassProbeView {
        let view = HorizontalSizeClassProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: HorizontalSizeClassProbeView, context _: Context) {
        uiView.onChange = onChange
        uiView.reportWindowSizeClass()
    }
}

private final class HorizontalSizeClassProbeView: UIView {
    var onChange: ((UIUserInterfaceSizeClass) -> Void)?
    private weak var observedWindow: UIWindow?
    private var traitRegistration: (any UITraitChangeRegistration)?
    private var lastReported: UIUserInterfaceSizeClass?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("HorizontalSizeClassProbeView is created in code only")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            detachTraitObserver()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachTraitObserverIfNeeded()
        reportWindowSizeClass()
    }

    private func detachTraitObserver() {
        if let observedWindow, let traitRegistration {
            observedWindow.unregisterForTraitChanges(traitRegistration)
        }
        observedWindow = nil
        traitRegistration = nil
    }

    private func attachTraitObserverIfNeeded() {
        guard observedWindow !== window else { return }
        detachTraitObserver()
        observedWindow = window
        traitRegistration = window?.registerForTraitChanges(
            [UITraitHorizontalSizeClass.self]
        ) { [weak self] (targetWindow: UIWindow, _) in
            self?.report(sizeClass: targetWindow.traitCollection.horizontalSizeClass)
        }
    }

    func reportWindowSizeClass() {
        guard let window else { return }
        report(sizeClass: window.traitCollection.horizontalSizeClass)
    }

    private func report(sizeClass: UIUserInterfaceSizeClass) {
        guard sizeClass != .unspecified, lastReported != sizeClass else { return }
        lastReported = sizeClass
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onChange?(sizeClass)
        }
    }
}

/// Presents a native `UIActivityViewController` from the topmost active
/// view controller with proper iPad `popoverPresentationController` anchoring,
/// avoiding the clipped `.sheet { ShareSheet().presentationDetents([.medium]) }`
/// SwiftUI wrapper pattern.
@MainActor
enum ActivitySharePresenter {
    static func present(
        items: [Any],
        sourceView: UIView? = nil,
        onFinish: ((Bool) -> Void)? = nil
    ) {
        guard let presenter = topMostViewController(),
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil,
              !presenter.isBeingDismissed else {
            onFinish?(false)
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        var didFinish = false
        activity.completionWithItemsHandler = { _, completed, _, _ in
            guard !didFinish else { return }
            didFinish = true
            onFinish?(completed)
        }
        if let popover = activity.popoverPresentationController {
            if let sourceView, sourceView.window != nil {
                popover.sourceView = sourceView
                popover.sourceRect = CGRect(
                    x: max(0, sourceView.bounds.maxX - 22),
                    y: 22,
                    width: 1,
                    height: 1
                )
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(activity, animated: true)
        if activity.presentingViewController == nil, !didFinish {
            didFinish = true
            onFinish?(false)
        }
    }

    private static func topMostViewController() -> UIViewController? {
        guard let window = AppWindowMetrics.current,
              let root = window.rootViewController else { return nil }
        var presenter = root
        while let presented = presenter.presentedViewController {
            if presented.isBeingDismissed { return nil }
            presenter = presented
        }
        return presenter
    }
}
