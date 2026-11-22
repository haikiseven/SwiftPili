import SwiftUI
import UIKit

/// Observes the iPhone tab root without owning navigation or bar visibility.
/// Saved capture intent makes runtime ON/OFF observable here; every sample also
/// requires the existing effective logger gate and an unrevoked access receipt.
struct RootTabBarDiagnostics: View {
    let tab: AppTab
    let coordinator: AppCoordinator
    @AppStorage("debug_logging_enabled") private var consoleRequested = false
    @AppStorage(PlaybackDebugRecorder.defaultsKey) private var reportRequested = false

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .phone,
           ExperimentalSettingsStore.shared.isAllowed(.diagnostics),
           consoleRequested || reportRequested || PlayerLog.debugRequestedAtLaunch {
            RootTabBarProbe(
                tab: tab,
                snapshot: RootTabBarSnapshot(tab: tab, coordinator: coordinator),
                currentSnapshot: { RootTabBarSnapshot(tab: tab, coordinator: coordinator) }
            )
        }
    }
}

private struct RootTabBarSnapshot: Equatable {
    let selectedTab: AppTab
    let path: [Route]
    let navigationRevision: UInt64
    let accountRevision: UInt64

    @MainActor
    init(tab: AppTab, coordinator: AppCoordinator) {
        selectedTab = coordinator.selectedTab
        path = coordinator.stack(for: tab)
        navigationRevision = coordinator.contentLinkNavigationRevision
        accountRevision = AccountManager.shared.identityRevision
    }

    var topKind: String {
        guard let route = path.last else { return "root" }
        switch route {
        case .videoDetail: return "videoDetail"
        case .liveRoom: return "liveRoom"
        case .userSpace: return "userSpace"
        case .search: return "search"
        case .favorites: return "favorites"
        case .history: return "history"
        case .following: return "following"
        case .followers: return "followers"
        case .watchLater: return "watchLater"
        case .downloads: return "downloads"
        case .offlinePlayer: return "offlinePlayer"
        case .offlinePager: return "offlinePager"
        case .messages: return "messages"
        case .chat: return "chat"
        case .favoriteDetail: return "favoriteDetail"
        case .bangumiDetail: return "bangumiDetail"
        case .momentDetail: return "momentDetail"
        case .articleReader: return "articleReader"
        case .musicInfo: return "musicInfo"
        case .inAppWeb: return "inAppWeb"
        }
    }
}

private struct RootTabBarProbe: UIViewControllerRepresentable {
    let tab: AppTab
    let snapshot: RootTabBarSnapshot
    let currentSnapshot: @MainActor () -> RootTabBarSnapshot

    func makeUIViewController(context _: Context) -> ProbeController {
        ProbeController(tab: tab)
    }

    func updateUIViewController(_ controller: ProbeController, context _: Context) {
        controller.update(snapshot: snapshot, currentSnapshot: currentSnapshot)
    }

    static func dismantleUIViewController(_ controller: ProbeController, coordinator _: ()) {
        controller.stop()
    }

    @MainActor
    final class ProbeController: UIViewController {
        private let probedTab: AppTab
        private var snapshot: RootTabBarSnapshot?
        private var currentSnapshot: (@MainActor () -> RootTabBarSnapshot)?
        private var access: ExperimentalAccessReceipt?
        private var generation: UInt64 = 0
        private var sampleSequence: UInt64 = 0
        private var transitionID: ObjectIdentifier?
        private var settledSample: Task<Void, Never>?
        private(set) var appearance = "unshown"

        init(tab: AppTab) {
            self.probedTab = tab
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func loadView() {
            let probe = UIView(frame: .zero)
            probe.backgroundColor = .clear
            probe.isUserInteractionEnabled = false
            probe.isAccessibilityElement = false
            view = probe
        }

        func update(
            snapshot: RootTabBarSnapshot,
            currentSnapshot: @escaping @MainActor () -> RootTabBarSnapshot
        ) {
            self.currentSnapshot = currentSnapshot
            guard self.snapshot != snapshot else { return }
            invalidatePendingSamples()
            self.snapshot = snapshot
            guard snapshot.selectedTab == probedTab else { return }
            observe("pathUpdate")
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            appearance = "willAppear"
            observe(appearance)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appearance = "didAppear"
            observe(appearance)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            appearance = "willDisappear"
            observe(appearance)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            appearance = "didDisappear"
            observe(appearance)
        }

        func stop() {
            invalidatePendingSamples()
            currentSnapshot = nil
            access = nil
        }

        private func invalidatePendingSamples() {
            generation &+= 1
            sampleSequence &+= 1
            settledSample?.cancel()
            settledSample = nil
            transitionID = nil
        }

        private func observe(_ event: String) {
            guard PlayerLog.isCapturing,
                  let receipt = ExperimentalSettingsPolicy.captureAccess(.diagnostics),
                  let state = currentSnapshot?() else {
                invalidatePendingSamples()
                access = nil
                return
            }
            if access != receipt {
                invalidatePendingSamples()
                access = receipt
            }
            emit(event, state: state)
            observeTransition(state: state, receipt: receipt)
            scheduleSettledSample(after: event, state: state, receipt: receipt)
        }

        private func emit(_ event: String, state: RootTabBarSnapshot) {
            guard PlayerLog.isCapturing, access?.isValid == true else { return }
            let navigation = enclosingNavigationController
            PlayerLog.log(RootTabBarObservation.line(
                event: event, tab: probedTab, state: state, navigation: navigation,
                probe: self
            ))
        }

        private func observeTransition(state: RootTabBarSnapshot, receipt: ExperimentalAccessReceipt) {
            guard let transition = enclosingNavigationController?.transitionCoordinator else { return }
            let identity = ObjectIdentifier(transition as AnyObject)
            guard transitionID != identity else { return }
            transitionID = identity
            let admittedGeneration = generation
            let registered = transition.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, self.generation == admittedGeneration,
                      self.transitionID == identity, self.access == receipt,
                      receipt.isValid, PlayerLog.isCapturing else { return }
                self.transitionID = nil
                guard self.currentSnapshot?() == state else { return }
                let event = context.isCancelled ? "transitionCancelled" : "transitionCompleted"
                self.emit(event, state: state)
                self.scheduleSettledSample(after: event, state: state, receipt: receipt)
            }
            if !registered { transitionID = nil }
        }

        private func scheduleSettledSample(
            after event: String, state: RootTabBarSnapshot, receipt: ExperimentalAccessReceipt
        ) {
            settledSample?.cancel()
            sampleSequence &+= 1
            let sequence = sampleSequence
            let admittedGeneration = generation
            // Two finite observations cover the next layout turn and the bar's
            // post-transition update. No display link, repeating timer or retry.
            settledSample = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.admits(sequence, generation: admittedGeneration, receipt: receipt, state: state)
                else { return }
                self.emit("nextTurn.\(event)", state: state)
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard self.admits(sequence, generation: admittedGeneration, receipt: receipt, state: state)
                else { return }
                self.emit("settled.\(event)", state: state)
                self.settledSample = nil
            }
        }

        private func admits(
            _ sequence: UInt64, generation: UInt64,
            receipt: ExperimentalAccessReceipt, state: RootTabBarSnapshot
        ) -> Bool {
            !Task.isCancelled && sampleSequence == sequence && self.generation == generation
                && access == receipt && receipt.isValid && PlayerLog.isCapturing && currentSnapshot?() == state
        }

        private var enclosingNavigationController: UINavigationController? {
            var candidate: UIViewController? = self
            while let controller = candidate {
                if let navigation = controller as? UINavigationController { return navigation }
                if let navigation = controller.navigationController { return navigation }
                candidate = controller.parent
            }
            return nil
        }
    }
}

/// Formatting reads only this probe's actual containing controllers. A missing
/// attachment is unavailable evidence, never a reason to select a global window.
@MainActor
private enum RootTabBarObservation {
    static func line(
        event: String, tab: AppTab, state: RootTabBarSnapshot,
        navigation: UINavigationController?, probe: RootTabBarProbe.ProbeController
    ) -> String {
        var fields = [
            "[TabBar] event=\(event)", "probeTab=\(tab.titleKey)",
            "selectedTab=\(state.selectedTab.titleKey)", "depth=\(state.path.count)",
            "top=\(state.topKind)", "navRevision=\(state.navigationRevision)",
            "accountRevision=\(state.accountRevision)", "appearance=\(probe.appearance)",
            "probeOnWindow=\(probe.viewIfLoaded?.window != nil)"
        ]
        guard let navigation else {
            return (fields + ["nativeNav=unavailable", "tabController=unavailable"]).joined(separator: " ")
        }
        fields += [
            "nativeNav=\(identity(navigation))", "nativeDepth=\(navigation.viewControllers.count)",
            "nativeTop=\(className(navigation.topViewController))",
            "nativeTransition=\(navigation.transitionCoordinator != nil)"
        ]
        guard let controller = navigation.tabBarController else {
            return (fields + ["tabController=unavailable"]).joined(separator: " ")
        }
        fields += [
            "tabController=\(identity(controller))", "nativeSelectedIndex=\(controller.selectedIndex)",
            "nativeSelected=\(identity(controller.selectedViewController))",
            "controllerHidden=\(controller.isTabBarHidden)", "minimizePolicy=\(minimizePolicy(controller))"
        ]
        guard controller.isViewLoaded else {
            return (fields + ["barView=unavailable.notLoaded"]).joined(separator: " ")
        }
        fields += barFields(controller.tabBar)
        return fields.joined(separator: " ")
    }

    private static func barFields(_ bar: UITabBar) -> [String] {
        var fields = [
            "barViewHidden=\(bar.isHidden)", "barAlpha=\(number(bar.alpha))",
            "barBounds=\(NSCoder.string(for: bar.bounds))", "barItems=\(bar.items?.count ?? 0)",
            "barSubviews=\(bar.subviews.count)", "barOnWindow=\(bar.window != nil)"
        ]
        guard let window = bar.window else { return fields + ["barWindowRect=unavailable"] }
        let rect = bar.convert(bar.bounds, to: window)
        fields += [
            "barWindowRect=\(NSCoder.string(for: rect))", "windowBounds=\(NSCoder.string(for: window.bounds))",
            "barIntersectsWindow=\(rect.intersects(window.bounds))", "windowHidden=\(window.isHidden)"
        ]
        if let presentation = bar.layer.presentation(), let superview = bar.superview {
            let rect = superview.convert(presentation.frame, to: window)
            fields += [
                "barPresentationRect=\(NSCoder.string(for: rect))",
                "barPresentationOpacity=\(number(CGFloat(presentation.opacity)))"
            ]
        }
        return fields + ancestorFields(bar)
    }

    private static func ancestorFields(_ bar: UITabBar) -> [String] {
        var ancestor = bar.superview
        var count = 0
        var alpha = bar.alpha
        var unusual: [String] = []
        while let view = ancestor, count < 16 {
            count += 1
            alpha *= view.alpha
            if view.isHidden || view.alpha < 0.999 {
                unusual.append("\(className(view)):hidden=\(view.isHidden),alpha=\(number(view.alpha))")
            }
            ancestor = view.superview
        }
        return [
            "ancestorAlphaProduct=\(number(alpha))",
            "hiddenOrFadedAncestors=\(unusual.isEmpty ? "none" : unusual.joined(separator: ";"))",
            "ancestorScanTruncated=\(ancestor != nil)"
        ]
    }

    private static func minimizePolicy(_ controller: UITabBarController) -> String {
        guard #available(iOS 26.0, *) else { return "unavailable.pre26" }
        switch controller.tabBarMinimizeBehavior {
        case .automatic: return "automatic"
        case .never: return "never"
        case .onScrollDown: return "onScrollDown"
        case .onScrollUp: return "onScrollUp"
        @unknown default: return "unknown"
        }
    }

    private static func className(_ object: AnyObject?) -> String {
        guard let object else { return "none" }
        return String(String(describing: type(of: object)).prefix(120))
    }

    private static func identity(_ object: AnyObject?) -> String {
        guard let object else { return "none" }
        return "\(className(object)):\(ObjectIdentifier(object))"
    }

    private static func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }
}
