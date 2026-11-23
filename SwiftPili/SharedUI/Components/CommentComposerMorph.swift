import SwiftUI

@MainActor
private final class MainTurnWork {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

@MainActor
func scheduleMainRunloopTurn(_ work: @escaping @MainActor () -> Void) {
    let boxed = MainTurnWork(work)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            boxed.run()
        }
    }
}

struct CommentComposerMorphContainer<ExpandedComposer: View>: View {
    let isExpanded: Bool
    let hasDraft: Bool
    var sourceIdentity: AnyHashable?
    let onExpand: () -> Void
    let expandedComposer: () -> ExpandedComposer

    @State private var presentedExpanded: Bool
    @State private var measuredComposerSize = CGSize(width: 340, height: 108)
    @State private var latestMeasuredSize: CGSize?
    @State private var hasMeasuredComposer = false
    @State private var windowIsLandscapeIPad = false
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppMotion private var motion

    init(
        isExpanded: Bool,
        hasDraft: Bool,
        sourceIdentity: AnyHashable? = nil,
        onExpand: @escaping () -> Void,
        @ViewBuilder expandedComposer: @escaping () -> ExpandedComposer
    ) {
        self.isExpanded = isExpanded
        self.hasDraft = hasDraft
        self.sourceIdentity = sourceIdentity
        self.onExpand = onExpand
        self.expandedComposer = expandedComposer
        _presentedExpanded = State(initialValue: isExpanded)
    }

    private var expandedHeight: CGFloat {
        max(measuredComposerSize.height, CommentComposerLauncher.diameter)
    }

    private var showsInlineExpanded: Bool { presentedExpanded && !windowIsLandscapeIPad }

    private var isDockedExpanded: Bool { presentedExpanded && windowIsLandscapeIPad }

    var body: some View {
        morphBackdrop
            .opacity(isDockedExpanded ? 0 : 1)
            .allowsHitTesting(!isDockedExpanded)
            .accessibilityHidden(isDockedExpanded)
            .overlay(alignment: .bottom) {
                if windowIsLandscapeIPad {
                    Color.clear.frame(height: 0)
                } else {
                    warmComposerLayer
                }
            }
            .background {
                IPadKeyboardDockPresenter(isPresented: isDockedExpanded) {
                    dockedComposer
                }
                .frame(width: 0, height: 0)
            }
            .iPadLandscapeWindowProbe($windowIsLandscapeIPad)
            .onChange(of: isExpanded) { _, expanded in
                handleExpansionChange(expanded)
            }
            .onChange(of: sourceIdentity) { _, _ in
                resetForSourceChange()
            }
    }

    @ViewBuilder
    private var morphBackdrop: some View {
        if !motion.reducesGeometry, !reduceTransparency, #available(iOS 26.0, *) {
            nativeLiquidGlassBackdrop
        } else if motion.reducesGeometry {
            reducedMotionBackdrop
        } else {
            continuousFallbackBackdrop
        }
    }

    @available(iOS 26.0, *)
    private var nativeLiquidGlassBackdrop: some View {
        GlassEffectContainer(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                if showsInlineExpanded {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: expandedHeight)
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                        )
                        .glassEffectID("composer", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                        .padding(.horizontal, AppSpacing.l)
                        .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
                } else {
                    CommentComposerLauncher(
                        hasDraft: hasDraft,
                        glassNamespace: glassNamespace,
                        action: onExpand
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
        }
    }

    private var reducedMotionBackdrop: some View {
        ZStack(alignment: .bottomTrailing) {
            if showsInlineExpanded {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: expandedHeight)
                    .composerFallbackPlatter(
                        cornerRadius: AppRadius.panel,
                        reduceTransparency: reduceTransparency
                    )
                    .padding(.horizontal, AppSpacing.l)
                    .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
                    .transition(.opacity)
            } else {
                CommentComposerLauncher(
                    hasDraft: hasDraft,
                    glassNamespace: nil,
                    action: onExpand
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
    }

    private var continuousFallbackBackdrop: some View {
        let collapsedDiameter = CommentComposerLauncher.diameter
        let platterRadius = showsInlineExpanded ? AppRadius.panel : CommentComposerLauncher.radius
        let launcherFadeAnimation: Animation = showsInlineExpanded
            ? .easeOut(duration: 0.11)
            : .easeOut(duration: 0.16).delay(0.08)
        return ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(maxWidth: showsInlineExpanded ? .infinity : collapsedDiameter)
                .frame(height: showsInlineExpanded ? expandedHeight : collapsedDiameter)
                .composerFallbackPlatter(
                    cornerRadius: platterRadius,
                    reduceTransparency: reduceTransparency
                )
                .padding(.horizontal, AppSpacing.l)
                .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)

            CommentComposerLauncher(
                hasDraft: hasDraft,
                glassNamespace: nil,
                showsSurface: false,
                action: onExpand
            )
            .animation(launcherFadeAnimation) { content in
                content.opacity(showsInlineExpanded ? 0 : 1)
            }
            .scaleEffect(showsInlineExpanded ? 0.84 : 1)
            .allowsHitTesting(!showsInlineExpanded)
            .accessibilityHidden(showsInlineExpanded)
        }
        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
    }

    private var warmComposerLayer: some View {
        let collapsedScale: CGFloat = 0.76
        let usesScale = !motion.reducesGeometry
        let opacityAnimation: Animation = motion.reducesGeometry
            ? motion.feedbackAnimation(normal: KeyboardAnimation.panelCollapse)
            : (presentedExpanded ? .easeOut(duration: 0.18).delay(0.06) : .easeOut(duration: 0.09))
        return expandedComposer()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                updateMeasuredComposerSize(newSize)
            }
            .animation(opacityAnimation) { content in
                content.opacity(presentedExpanded ? 1 : 0)
            }
            .scaleEffect(
                (!usesScale || presentedExpanded) ? 1 : collapsedScale,
                anchor: .bottomTrailing
            )
            .allowsHitTesting(presentedExpanded)
            .accessibilityHidden(!presentedExpanded)
            .padding(.horizontal, AppSpacing.l)
            .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
    }

    private var dockedComposer: some View {
        expandedComposer()
            .fixedSize(horizontal: false, vertical: true)
            .composerDockSurface(reduceTransparency: reduceTransparency)
    }

    private func updateMeasuredComposerSize(_ newSize: CGSize) {
        guard newSize.width.isFinite, newSize.height.isFinite,
              newSize.width > 0, newSize.height > 0 else { return }
        latestMeasuredSize = newSize
        let sizeChanged = abs(measuredComposerSize.width - newSize.width) > 0.5
            || abs(measuredComposerSize.height - newSize.height) > 0.5
        if !hasMeasuredComposer || (!presentedExpanded && !isExpanded) {
            hasMeasuredComposer = true
            if sizeChanged {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    measuredComposerSize = newSize
                }
            }
            return
        }
        hasMeasuredComposer = true
        guard sizeChanged else { return }
        if presentedExpanded && isExpanded {
            withAnimation(motion.animation(normal: KeyboardAnimation.panelExpand)) {
                measuredComposerSize = newSize
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                measuredComposerSize = newSize
            }
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        guard presentedExpanded != expanded else { return }
        if expanded, let latest = latestMeasuredSize,
           abs(measuredComposerSize.width - latest.width) > 0.5
            || abs(measuredComposerSize.height - latest.height) > 0.5 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                measuredComposerSize = latest
            }
        }
        let animation: Animation = motion.reducesGeometry
            ? motion.feedbackAnimation(normal: KeyboardAnimation.panelCollapse)
            : (expanded ? KeyboardAnimation.panelExpand : KeyboardAnimation.panelCollapse)
        withAnimation(animation) {
            presentedExpanded = expanded
        }
    }

    private func resetForSourceChange() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasMeasuredComposer = false
            latestMeasuredSize = nil
            presentedExpanded = isExpanded
        }
    }
}

struct CommentComposerLauncherGlyph: View {
    let hasDraft: Bool

    var body: some View {
        Image(systemName: "square.and.pencil")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(
                width: CommentComposerLauncher.diameter,
                height: CommentComposerLauncher.diameter
            )
            .overlay(alignment: .topTrailing) {
                if hasDraft {
                    Circle()
                        .fill(Color.biliAccent)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: -3, y: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

struct CommentComposerLauncher: View {
    static let diameter: CGFloat = 48
    static var radius: CGFloat { diameter * 0.5 }
    let hasDraft: Bool
    var glassNamespace: Namespace.ID?
    var showsSurface = true
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        launcherSurface
            .accessibilityLabel(Self.accessibilityTitle(hasDraft: hasDraft))
            .padding(.horizontal, AppSpacing.l)
            .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
    }

    @ViewBuilder
    private var launcherSurface: some View {
        let baseButton = Button(action: action) {
            CommentComposerLauncherGlyph(hasDraft: hasDraft)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)

        if !showsSurface {
            baseButton
        } else if !reduceTransparency, #available(iOS 26.0, *) {
            if let glassNamespace {
                baseButton
                    .glassEffect(.regular.interactive(), in: Circle())
                    .glassEffectID("composer", in: glassNamespace)
                    .glassEffectTransition(.matchedGeometry)
            } else {
                baseButton
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            baseButton
                .composerFallbackPlatter(
                    cornerRadius: Self.radius,
                    reduceTransparency: reduceTransparency
                )
        }
    }

    static func accessibilityTitle(hasDraft: Bool) -> Text {
        hasDraft ? Text("Continue editing comment draft") : Text("Write a comment")
    }
}

private extension View {
    func composerDockSurface(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return floatingGlassInputSurface(in: shape, interactive: true, reduceTransparency: reduceTransparency)
    }

    func composerFallbackPlatter(cornerRadius: CGFloat, reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return floatingGlassInputSurface(in: shape, interactive: false, reduceTransparency: reduceTransparency)
    }
}
