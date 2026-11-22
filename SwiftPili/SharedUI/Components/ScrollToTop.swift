import SwiftUI

struct ScrollTopAnchor: View {
    static let id = "scroll-top-anchor"

    var body: some View {
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
    func scrollsToTopOnTabReselect(
        _ tab: AppTab,
        isActive: Bool = true,
        refresh: (@MainActor @Sendable (ScrollViewProxy) async -> Void)? = nil
    ) -> some View {
        modifier(ScrollToTopOnTabReselect(tab: tab, isActive: isActive, refresh: refresh))
    }
}
