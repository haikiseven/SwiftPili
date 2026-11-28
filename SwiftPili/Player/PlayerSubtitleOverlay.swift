import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct SubtitleStyledCaptionView: View {
    let primaryText: String?
    let secondaryText: String?
    let isFullscreen: Bool
    let fontSizeScale: SubtitleFontSizeScale
    let backgroundStyle: SubtitleBackgroundStyle
    let backgroundOpacity: Double

    private var cleanPrimary: String? {
        guard let text = primaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private var cleanSecondary: String? {
        guard let text = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private var primaryFontSize: CGFloat {
        (isFullscreen ? 20 : 13) * fontSizeScale.multiplier
    }

    private var secondaryFontSize: CGFloat {
        max(10, (isFullscreen ? 17 : 11) * fontSizeScale.multiplier)
    }

    private var captionBackgroundColor: Color {
        switch backgroundStyle {
        case .noneWithStroke:
            .clear
        case .translucentBox:
            .black.opacity(SubtitleStylePreferences.clampOpacity(backgroundOpacity))
        case .solidBox:
            .black
        }
    }

    var body: some View {
        if cleanPrimary != nil || cleanSecondary != nil {
            VStack(spacing: isFullscreen ? 4 : 2) {
                if let primary = cleanPrimary {
                    styledText(
                        primary,
                        size: primaryFontSize,
                        weight: .medium,
                        opacity: 1.0
                    )
                }
                if let secondary = cleanSecondary {
                    styledText(
                        secondary,
                        size: secondaryFontSize,
                        weight: .regular,
                        opacity: 0.88
                    )
                }
            }
            .padding(.horizontal, backgroundStyle == .noneWithStroke ? 4 : 11)
            .padding(.vertical, backgroundStyle == .noneWithStroke ? 2 : 5)
            .background(
                captionBackgroundColor,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private func styledText(
        _ content: String,
        size: CGFloat,
        weight: Font.Weight,
        opacity: Double
    ) -> some View {
        let base = Text(content)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

        if backgroundStyle == .noneWithStroke {
            base
                .shadow(color: .black.opacity(0.95), radius: 1.2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.9), radius: 0.6, x: 0, y: 0)
                .shadow(color: .black.opacity(0.75), radius: 3.0, x: 0, y: 0)
        } else {
            base
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0.5)
        }
    }
}

/// Invisible SwiftUI bridge that hosts Apple's `.translationTask` modifier on whichever
/// player surface or settings sheet currently owns top-most translation host priority.
struct SubtitleTranslationHostBridge: View {
    let player: PlayerViewModel
    let priority: Int

    @State private var hostID = UUID()
    #if canImport(Translation)
    @State private var configuration: TranslationSession.Configuration?
    @State private var activeKey: SubtitleTranslationSessionKey?
    #endif

    private var desiredKey: SubtitleTranslationSessionKey? {
        guard player.activeTranslationHostID == hostID else { return nil }
        return player.subtitleTranslationSessionKey
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                player.registerSubtitleTranslationHost(hostID, priority: priority)
            }
            .onChange(of: priority) { _, newPriority in
                player.registerSubtitleTranslationHost(hostID, priority: newPriority)
            }
            .onDisappear {
                #if canImport(Translation)
                configuration = nil
                activeKey = nil
                #endif
                player.unregisterSubtitleTranslationHost(hostID)
            }
            #if canImport(Translation)
            .onChange(of: desiredKey, initial: true) { _, newKey in
                syncConfiguration(for: newKey)
            }
            .translationTask(
                configuration,
                action: Self.makeTranslationAction(
                    service: player.session.subtitleTranslationService,
                    hostID: hostID
                )
            )
            #endif
    }

    #if canImport(Translation)
    private nonisolated static func makeTranslationAction(
        service: SystemSubtitleTranslationService,
        hostID: UUID
    ) -> (TranslationSession) async -> Void {
        { session in
            guard let key = await service.activeSessionKey(for: hostID) else { return }
            await SystemSubtitleTranslationService.runTranslationSession(
                session,
                service: service,
                sessionKey: key
            )
        }
    }

    private func syncConfiguration(for newKey: SubtitleTranslationSessionKey?) {
        guard let newKey else {
            activeKey = nil
            configuration = nil
            return
        }
        let previousKey = activeKey
        activeKey = newKey
        let sourceLanguage = newKey.sourceIdentifier.map { Locale.Language(identifier: $0) }
        let targetLanguage = Locale.Language(identifier: newKey.targetIdentifier)
        if var existing = configuration,
           previousKey?.sourceIdentifier == newKey.sourceIdentifier,
           previousKey?.targetIdentifier == newKey.targetIdentifier {
            if previousKey?.revision != newKey.revision {
                existing.invalidate()
                configuration = existing
            }
        } else {
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage
            )
        }
    }
    #endif
}

struct PlayerSubtitleLayoutPadding: Equatable, Sendable {
    static let portraitAvoidanceBaseBottom: CGFloat = 158
    static let storyMetadataAvoidanceBaseBottom: CGFloat = 232

    let avoidsPortraitAlwaysOnChrome: Bool
    let leading: CGFloat
    let trailing: CGFloat
    let bottom: CGFloat

    static func resolve(
        isFullscreenHost: Bool,
        isPlayerFullscreen: Bool,
        isPortraitContent: Bool,
        mode: PlayerMode,
        portraitPureViewEnabled: Bool,
        portraitChromeBottomInset: CGFloat,
        styleBottomOffset: Double
    ) -> Self {
        let avoids = isFullscreenHost
            && isPortraitContent
            && mode != .live
            && !portraitPureViewEnabled
        let portraitExtraSafeArea = max(0, portraitChromeBottomInset - PlayerChromeInsets.fullscreenBottomFloor)
        let bottom = (
            avoids
                ? (Self.portraitAvoidanceBaseBottom + portraitExtraSafeArea)
                : (isPlayerFullscreen ? 52 : 28)
        ) + CGFloat(styleBottomOffset)
        return Self(
            avoidsPortraitAlwaysOnChrome: avoids,
            leading: avoids ? 20 : 24,
            trailing: avoids ? 64 : 24,
            bottom: bottom
        )
    }

    static func resolve(
        isFullscreenHost: Bool,
        isPlayerFullscreen: Bool,
        isPortraitContent: Bool,
        isPortraitImmersive: Bool,
        mode: PlayerMode,
        portraitPureViewEnabled: Bool,
        portraitChromeBottomInset: CGFloat,
        controlsVisible: Bool,
        bottomSafeArea: CGFloat,
        styleBottomOffset: Double
    ) -> Self {
        let avoids = isFullscreenHost
            && isPortraitImmersive
            && mode != .live
            && !portraitPureViewEnabled
        let baseBottom: CGFloat
        if avoids {
            let portraitExtraSafeArea = max(0, portraitChromeBottomInset - PlayerChromeInsets.fullscreenBottomFloor)
            baseBottom = Self.storyMetadataAvoidanceBaseBottom + portraitExtraSafeArea
        } else if isPortraitImmersive && portraitPureViewEnabled {
            let effectiveBottomSafe = max(bottomSafeArea, portraitChromeBottomInset)
            baseBottom = max(52, effectiveBottomSafe + 36)
        } else if isPlayerFullscreen {
            baseBottom = controlsVisible
                ? ((mode.isSeekable ? 102 : 96) + bottomSafeArea)
                : max(28, bottomSafeArea + 18)
        } else {
            baseBottom = controlsVisible
                ? ((mode.isSeekable ? 86 : 74) + bottomSafeArea)
                : (28 + bottomSafeArea)
        }
        return Self(
            avoidsPortraitAlwaysOnChrome: avoids,
            leading: avoids ? 20 : 24,
            trailing: avoids ? 64 : 24,
            bottom: max(0, baseBottom + CGFloat(styleBottomOffset))
        )
    }
}

struct PlayerSubtitleOverlay: View {
    let player: PlayerViewModel
    var isFullscreenSurface: Bool? = nil
    var portraitChromeBottomInset: CGFloat = 0
    var isPortraitImmersive: Bool? = nil
    var controlsVisible: Bool? = nil
    var bottomSafeArea: CGFloat? = nil
    private let stylePreferences = SubtitleStylePreferences.shared

    var body: some View {
        let primary = player.subtitleText
        let secondary = player.secondarySubtitleText
        let hasPrimary = primary.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let hasSecondary = secondary.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let isFullscreenHost = isFullscreenSurface ?? player.isFullscreen
        let isImmersivePresentation = player.isFullscreen || isFullscreenHost
        let effectivePortraitImmersive = isPortraitImmersive
            ?? (isFullscreenHost && (player.isPortraitContent || portraitChromeBottomInset > 0) && player.mode != .live)
        let effectiveControlsVisible = controlsVisible
            ?? (effectivePortraitImmersive ? false : player.showControls)
        let effectiveBottomSafeArea = bottomSafeArea ?? portraitChromeBottomInset
        let padding = PlayerSubtitleLayoutPadding.resolve(
            isFullscreenHost: isFullscreenHost,
            isPlayerFullscreen: isImmersivePresentation,
            isPortraitContent: player.isPortraitContent || portraitChromeBottomInset > 0,
            isPortraitImmersive: effectivePortraitImmersive,
            mode: player.mode,
            portraitPureViewEnabled: player.portraitPureViewEnabled,
            portraitChromeBottomInset: portraitChromeBottomInset,
            controlsVisible: effectiveControlsVisible,
            bottomSafeArea: effectiveBottomSafeArea,
            styleBottomOffset: stylePreferences.bottomOffset
        )

        ZStack(alignment: .bottom) {
            if hasPrimary || hasSecondary {
                SubtitleStyledCaptionView(
                    primaryText: primary,
                    secondaryText: secondary,
                    isFullscreen: isImmersivePresentation,
                    fontSizeScale: stylePreferences.fontSizeScale,
                    backgroundStyle: stylePreferences.backgroundStyle,
                    backgroundOpacity: stylePreferences.backgroundOpacity
                )
                .padding(.leading, padding.leading)
                .padding(.trailing, padding.trailing)
                .padding(.bottom, padding.bottom)
                .animation(.easeInOut(duration: 0.2), value: padding)
            }

            if player.hasAnyActiveSubtitle || player.isAutoTranslationEnabled {
                SubtitleTranslationHostBridge(
                    player: player,
                    priority: isFullscreenHost ? 1 : 0
                )
            }
        }
        .allowsHitTesting(false)
    }
}
