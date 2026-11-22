import SwiftUI

/// Zero-size marker placed at the top of a screen's scroll content —
/// the tab re-tap scrolls back to it.
struct ScrollTopAnchor: View {
    static let id = "scroll-top-anchor"

    var body: some View {
        // 0×0, not fullwidth×0: a zero-HEIGHT color layer still asks
        // CoreAnimation for a 1260x0 backing store, which fails with
        // "Failed to create image slot (os/kern failure)" on every
        // feed render. A zero-AREA view creates no layer contents.
        Color.clear
            .frame(width: 0, height: 0)
            .id(Self.id)
    }
}

private struct ScrollToTopOnTabReselect: ViewModifier {
    @AppMotion private var motion
    let tab: AppTab
    let isActive: Bool
    let refresh: (@MainActor @Sendable (ScrollViewProxy) async -> Void)?
    @Environment(AppCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            refreshableContent(content, proxy: proxy)
                .onChange(of: coordinator.scrollToTopTick) {
                    guard isActive, coordinator.selectedTab == tab else { return }
                    withAnimation(motion.animation(normal: .easeInOut(duration: 0.3))) {
                        proxy.scrollTo(ScrollTopAnchor.id, anchor: .top)
                    }
                }
        }
    }

    @ViewBuilder
    private func refreshableContent(_ content: Content, proxy: ScrollViewProxy) -> some View {
        if let refresh {
            content.refreshable { @MainActor in
                await refresh(proxy)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Re-tapping `tab` while already at its root scrolls this container
    /// to the top. The scroll content must include a ScrollTopAnchor (or
    /// a view tagged with ScrollTopAnchor.id).
    /// An optional refresh action receives the same reader's proxy.
    func scrollsToTopOnTabReselect(
        _ tab: AppTab,
        isActive: Bool = true,
        refresh: (@MainActor @Sendable (ScrollViewProxy) async -> Void)? = nil
    ) -> some View {
        modifier(ScrollToTopOnTabReselect(tab: tab, isActive: isActive, refresh: refresh))
    }
}
