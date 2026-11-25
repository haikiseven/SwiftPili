import SwiftUI
import UIKit

struct LivePortraitSafeAreaLayout: Equatable, Sendable {
    static let topDesignSpacing: CGFloat = 12
    static let bottomDesignSpacing: CGFloat = 10

    let topSafeAreaInset: CGFloat
    let physicalBottomSafeAreaInset: CGFloat
    let effectiveBottomSafeAreaInset: CGFloat
    let keyboardDisplacement: CGFloat
    let topOverlayPadding: CGFloat
    let bottomOverlayPadding: CGFloat

    static func resolve(
        isImmersivePortrait: Bool,
        topSafeAreaInset: CGFloat,
        physicalBottomSafeAreaInset: CGFloat,
        keyboardEffectiveBottomInset: CGFloat? = nil,
        topDesignSpacing: CGFloat = Self.topDesignSpacing,
        bottomDesignSpacing: CGFloat = Self.bottomDesignSpacing
    ) -> Self {
        guard isImmersivePortrait else {
            return Self(
                topSafeAreaInset: 0,
                physicalBottomSafeAreaInset: 0,
                effectiveBottomSafeAreaInset: 0,
                keyboardDisplacement: 0,
                topOverlayPadding: 0,
                bottomOverlayPadding: 0
            )
        }

        let topSpacing = max(0, topDesignSpacing)
        let bottomSpacing = max(0, bottomDesignSpacing)
        let topInset = max(0, topSafeAreaInset)
        let physicalBottomInset = max(0, physicalBottomSafeAreaInset)
        let keyboardInset = max(0, keyboardEffectiveBottomInset ?? physicalBottomInset)
        let effectiveBottomInset = max(physicalBottomInset, keyboardInset)

        return Self(
            topSafeAreaInset: topInset,
            physicalBottomSafeAreaInset: physicalBottomInset,
            effectiveBottomSafeAreaInset: effectiveBottomInset,
            keyboardDisplacement: max(0, effectiveBottomInset - physicalBottomInset),
            topOverlayPadding: topInset + topSpacing,
            bottomOverlayPadding: effectiveBottomInset + bottomSpacing
        )
    }
}

extension LivePortraitSafeAreaLayout {
    func hostChromeExtent(
        metrics: LivePortraitOverlayMetrics,
        hasInput: Bool,
        hasTransport: Bool = false
    ) -> LiveHostChromeExtent {
        LiveHostChromeExtent(
            top: max(0, topOverlayPadding) + max(0, metrics.reservedHeaderHeight),
            bottom: max(0, bottomOverlayPadding)
                + (hasInput ? max(0, metrics.reservedInputHeight) : 0)
                + (hasTransport ? max(0, metrics.reservedTransportHeight) : 0),
            bottomInterceptsTouches: metrics.showsChatList
        )
    }
}

struct LiveKeyboardFrameTracker: ViewModifier {
    @Binding var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { notification in
                guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
                      value.cgRectValue.width > 0, value.cgRectValue.height > 0 else {
                    frame = nil
                    return
                }
                frame = value.cgRectValue
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                frame = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                frame = nil
            }
    }
}

struct LiveHostChromeExtent: Equatable, Sendable {
    let top: CGFloat
    let bottom: CGFloat
    let bottomInterceptsTouches: Bool
}

struct LivePortraitKeyboardLayout: Equatable, Sendable {
    private static let bottomIntersectionTolerance: CGFloat = 1

    static func effectiveBottomInset(
        physicalBottomInset: CGFloat,
        keyboardFrame: CGRect?,
        containerFrame: CGRect
    ) -> CGFloat {
        let physical = max(0, physicalBottomInset)
        guard let keyboardFrame,
              keyboardFrame.width > 0,
              keyboardFrame.height > 0,
              keyboardFrame.minX.isFinite,
              keyboardFrame.maxX.isFinite,
              keyboardFrame.minY.isFinite,
              keyboardFrame.maxY.isFinite,
              containerFrame.width > 0,
              containerFrame.height > 0
        else {
            return physical
        }

        let horizontalOverlap = min(containerFrame.maxX, keyboardFrame.maxX)
            - max(containerFrame.minX, keyboardFrame.minX)
        guard horizontalOverlap > 0,
              keyboardFrame.maxY >= containerFrame.maxY - bottomIntersectionTolerance
        else {
            return physical
        }

        let overlapTop = max(containerFrame.minY, keyboardFrame.minY)
        let overlapBottom = min(containerFrame.maxY, keyboardFrame.maxY)
        let keyboardOverlap = max(0, overlapBottom - overlapTop)
        return max(physical, keyboardOverlap)
    }
}

struct ImmersiveChromeFade: ViewModifier {
    let isActive: Bool
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .animation(animation, value: isActive)
    }
}

struct LivePortraitOverlayMetrics: Equatable, Sendable {
    static let minimumInputHeight: CGFloat = 44
    static let preferredChatHeight: CGFloat = 300
    static let minimumHeaderHeight: CGFloat = 56
    static let transportRowSpacing: CGFloat = 6
    static let immersiveMinimumHeaderHeight: CGFloat = 64

    let availableHeight: CGFloat
    let reservedHeaderHeight: CGFloat
    let reservedInputHeight: CGFloat
    let reservedTransportHeight: CGFloat
    let chatHeight: CGFloat

    var showsChatList: Bool { chatHeight > 0 }
    var reservedBottomHeight: CGFloat { reservedInputHeight + reservedTransportHeight }

    static func reservedHeader(
        headerHeight: CGFloat,
        minimumHeaderHeight: CGFloat = Self.minimumHeaderHeight
    ) -> CGFloat {
        max(max(0, minimumHeaderHeight), max(0, headerHeight))
    }

    static func reservedInput(
        inputHeight: CGFloat,
        minimumInputHeight: CGFloat = Self.minimumInputHeight
    ) -> CGFloat {
        max(max(0, minimumInputHeight), max(0, inputHeight))
    }

    static func resolve(
        containerHeight: CGFloat,
        topOverlayPadding: CGFloat,
        bottomOverlayPadding: CGFloat,
        headerHeight: CGFloat,
        inputHeight: CGFloat,
        preferredChatHeight: CGFloat = Self.preferredChatHeight,
        minimumInputHeight: CGFloat = Self.minimumInputHeight,
        transportHeight: CGFloat = 0,
        minimumTransportHeight: CGFloat = 0,
        minimumHeaderHeight: CGFloat = Self.minimumHeaderHeight
    ) -> Self {
        let availableHeight = max(
            0,
            containerHeight - max(0, topOverlayPadding) - max(0, bottomOverlayPadding)
        )
        let reservedInputHeight = reservedInput(
            inputHeight: inputHeight,
            minimumInputHeight: minimumInputHeight
        )
        let reservedTransportHeight = reservedInput(
            inputHeight: transportHeight,
            minimumInputHeight: minimumTransportHeight
        )
        let reservedHeaderHeight = reservedHeader(
            headerHeight: headerHeight,
            minimumHeaderHeight: minimumHeaderHeight
        )
        let chatSpace = max(
            0,
            availableHeight - reservedHeaderHeight - reservedInputHeight - reservedTransportHeight
        )
        let chatHeight = min(max(0, preferredChatHeight), chatSpace)

        return Self(
            availableHeight: availableHeight,
            reservedHeaderHeight: reservedHeaderHeight,
            reservedInputHeight: reservedInputHeight,
            reservedTransportHeight: reservedTransportHeight,
            chatHeight: chatHeight
        )
    }
}

struct LivePortraitHostLayout: Equatable, Sendable {
    let showsArea: Bool
    let showsPopularity: Bool
    let showsQualityLabel: Bool

    static func resolve(
        width: CGFloat,
        isAccessibilitySize: Bool = false
    ) -> Self {
        let normalizedWidth = max(0, width)
        if isAccessibilitySize || normalizedWidth <= 320 {
            return Self(showsArea: false, showsPopularity: false, showsQualityLabel: false)
        }
        if normalizedWidth < 390 {
            return Self(showsArea: false, showsPopularity: true, showsQualityLabel: false)
        }
        return Self(showsArea: true, showsPopularity: true, showsQualityLabel: true)
    }
}

struct LiveAreaBreadcrumb: View {
    let parentAreaName: String
    let areaName: String
    let textStyle: AnyShapeStyle
    let separatorStyle: AnyShapeStyle

    private var levels: [String] {
        [parentAreaName, areaName].filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .imageScale(.small)
                        .foregroundStyle(separatorStyle)
                        .accessibilityHidden(true)
                }
                Text(level)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(textStyle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(levels.joined(separator: ", ")))
    }
}

struct LiveStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LivePortraitInputBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct LivePortraitTransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct LivePortraitHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum LiveRoomAvailability: Equatable {
    case loading
    case live
    case roundPlay
    case offline

    static func resolve(liveStatus: Int?) -> Self {
        guard let liveStatus else { return .loading }
        switch LiveRoomStatusPolicy.state(liveStatus: liveStatus) {
        case .live: return .live
        case .roundPlay: return .roundPlay
        case .offline: return .offline
        case .unknown: return .live
        }
    }

    var isOffline: Bool { self == .offline }

    var statusText: String {
        switch self {
        case .loading: String(localized: "LIVE")
        case .live: String(localized: "LIVE")
        case .roundPlay: String(localized: "ROUND")
        case .offline: String(localized: "OFFLINE")
        }
    }

    var announcedStatusText: String? {
        switch self {
        case .loading, .live: nil
        case .roundPlay: String(localized: "ROUND")
        case .offline: String(localized: "OFFLINE")
        }
    }

    var statusColor: Color {
        switch self {
        case .loading: .secondary
        case .live: .red
        case .roundPlay: .orange
        case .offline: .secondary
        }
    }
}

enum LiveChatRenderPolicy {
    static let standardVisibleMessageLimit = 200
    static let immersiveVisibleMessageLimit = 80

    static func standardVisibleMessages(
        from messages: [ChatMessage]
    ) -> ArraySlice<ChatMessage> {
        messages.suffix(standardVisibleMessageLimit)
    }

    static func immersiveVisibleMessages(
        from messages: [ChatMessage]
    ) -> ArraySlice<ChatMessage> {
        messages.suffix(immersiveVisibleMessageLimit)
    }
}

final class LiveChatAutoScrollPolicy<ID: Hashable> {
    private(set) var lastRequestedID: ID?

    func nextTarget(for latestID: ID?) -> ID? {
        guard let latestID else {
            lastRequestedID = nil
            return nil
        }
        guard latestID != lastRequestedID else { return nil }
        lastRequestedID = latestID
        return latestID
    }

    func reset() {
        lastRequestedID = nil
    }
}
