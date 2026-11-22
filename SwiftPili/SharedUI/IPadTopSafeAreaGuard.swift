import SwiftUI
import UIKit

extension View {
    @ViewBuilder
    func guardIPadTopSafeArea(when isEnabled: Bool = true) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            modifier(IPadTopSafeAreaGuardModifier(isEnabled: isEnabled))
        } else {
            self
        }
    }
}

private struct IPadTopSafeAreaGuardModifier: ViewModifier {
    let isEnabled: Bool
    @State private var windowTopInset: CGFloat = 0
    @State private var layoutTopInset: CGFloat = 0
    @State private var originY: CGFloat = 0

    private var coveredTopInset: CGFloat {
        max(originY, layoutTopInset)
    }

    private var extraTopPadding: CGFloat {
        guard isEnabled,
              windowTopInset.isFinite, layoutTopInset.isFinite, originY.isFinite,
              windowTopInset > 0,
              coveredTopInset < windowTopInset - 1 else {
            return 0
        }
        return max(0, windowTopInset - coveredTopInset)
    }

    func body(content: Content) -> some View {
        content
            .padding(.top, extraTopPadding)
            .background {
                GeometryReader { geometry in
                    let top = geometry.safeAreaInsets.top
                    let globalMinY = geometry.frame(in: .global).minY
                    Color.clear
                        .onAppear {
                            updateLayoutTopInset(top)
                            updateOriginY(globalMinY)
                        }
                        .onChange(of: top) { _, newValue in
                            updateLayoutTopInset(newValue)
                        }
                        .onChange(of: globalMinY) { _, newValue in
                            updateOriginY(newValue)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background {
                WindowTopSafeAreaProbe { top in
                    updateWindowTopInset(top)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private func updateWindowTopInset(_ value: CGFloat) {
        guard value.isFinite else { return }
        let normalized = max(0, value)
        if abs(windowTopInset - normalized) >= 0.5 {
            windowTopInset = normalized
        }
    }

    private func updateLayoutTopInset(_ value: CGFloat) {
        guard value.isFinite else { return }
        let normalized = max(0, value)
        if abs(layoutTopInset - normalized) >= 0.5 {
            layoutTopInset = normalized
        }
    }

    private func updateOriginY(_ value: CGFloat) {
        guard value.isFinite else { return }
        let normalized = max(0, value)
        if abs(originY - normalized) >= 0.5 {
            originY = normalized
        }
    }
}

private struct WindowTopSafeAreaProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context _: Context) -> TopSafeAreaProbeView {
        let view = TopSafeAreaProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TopSafeAreaProbeView, context _: Context) {
        uiView.onChange = onChange
        uiView.reportIfNeeded()
    }
}

private final class TopSafeAreaProbeView: UIView {
    var onChange: ((CGFloat) -> Void)?
    private var lastReported: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("TopSafeAreaProbeView is created in code only")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportIfNeeded()
    }

    func reportIfNeeded() {
        guard let window else { return }
        let windowTop = window.safeAreaInsets.top.isFinite ? max(0, window.safeAreaInsets.top) : 0
        if let lastReported, abs(lastReported - windowTop) < 0.5 { return }
        lastReported = windowTop
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.onChange?(windowTop)
        }
    }
}
