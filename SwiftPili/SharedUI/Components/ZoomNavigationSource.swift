import SwiftUI

/// The tapped card a route was opened from, carried as route PAYLOAD only.
///
/// Equality and hashing ignore it on purpose (the same rule as
/// `VideoRouteTarget.preview`): the zoom origin describes how a destination
/// arrived, never which destination it is. Two openings of one live room are
/// one route, so path diffing, presentation identity and player ownership
/// cannot fork on it.
struct RouteZoomSource: Hashable, Sendable {
    let id: UUID?

    static let none = RouteZoomSource(id: nil)

    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

private struct NavigationZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct ZoomSourceAnchorBinding: Sendable {
    let id: UUID
    let reportsPreference: Bool
}

private struct ZoomSourceAnchorKey: EnvironmentKey {
    static let defaultValue: ZoomSourceAnchorBinding? = nil
}

private struct ZoomDestinationSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ZoomSourceAnchoredKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension EnvironmentValues {
    /// One namespace per navigation tree, owned by `RootView`. Native Zoom only
    /// pairs a source and a destination inside the same `NavigationStack`.
    var navigationZoomNamespace: Namespace.ID? {
        get { self[NavigationZoomNamespaceKey.self] }
        set { self[NavigationZoomNamespaceKey.self] = newValue }
    }

    fileprivate var zoomSourceAnchor: ZoomSourceAnchorBinding? {
        get { self[ZoomSourceAnchorKey.self] }
        set { self[ZoomSourceAnchorKey.self] = newValue }
    }

    /// Set on the first page of the iPad detail presentation: the presentation
    /// itself carries that page's zoom, so the page must not declare a second
    /// one. Pushed destinations do not inherit it — they take the stack's
    /// environment, not this page's.
    var zoomDestinationSuppressed: Bool {
        get { self[ZoomDestinationSuppressedKey.self] }
        set { self[ZoomDestinationSuppressedKey.self] = newValue }
    }
}

/// Controls whether `ZoomSourceButton` registers its transition source on the
/// outer button, defers to a descendant `.zoomSourceAnchor(...)`, or probes
/// dynamically via preference propagation.
enum ZoomSourceBindingMode: Sendable {
    case automatic
    case outerContainer
    case childAnchor
}

/// A button whose label is the origin of the native Zoom transition into the
/// route it opens.
///
/// The source belongs to this rendered occurrence, not to the content: `id`
/// resets it when a reused cell starts showing different content. A card that
/// draws its own platter claims the source with `zoomSourceAnchor(cornerRadius:)`
/// so the zoom grows out of the platter rather than the label's padded frame;
/// any other label is the source itself, clipped to `cornerRadius` when given.
struct ZoomSourceButton<Label: View>: View {
    var id: AnyHashable?
    var isEnabled = true
    var cornerRadius: CGFloat?
    var anchorMode: ZoomSourceBindingMode = .automatic
    var isCurrent: () -> Bool = { true }
    let open: (RouteZoomSource) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZoomSourceButtonBody(
            isEnabled: isEnabled, cornerRadius: cornerRadius,
            anchorMode: anchorMode, isCurrent: isCurrent,
            open: open, label: label
        )
        .id(id)
    }
}

private struct ZoomSourceButtonBody<Label: View>: View {
    let isEnabled: Bool
    let cornerRadius: CGFloat?
    let anchorMode: ZoomSourceBindingMode
    let isCurrent: () -> Bool
    let open: (RouteZoomSource) -> Void
    @ViewBuilder var label: () -> Label
    @State private var sourceID = UUID()
    @State private var isAnchored = false
    @Environment(\.navigationZoomNamespace) private var namespace

    /// Distinct from `sourceID` so an anchored button's outer modifier never
    /// matches a destination's `sourceID`, while staying in the same
    /// `@ViewBuilder` branch as its unanchored state when the preference lands.
    private struct StandDown: Hashable {
        let id: UUID
    }

    var body: some View {
        let button = Button {
            guard isCurrent() else { return }
            let usesZoom = namespace != nil && !UIAccessibility.isReduceMotionEnabled
            open(usesZoom ? RouteZoomSource(id: sourceID) : .none)
        } label: {
            switch anchorMode {
            case .automatic:
                label()
                    .environment(
                        \.zoomSourceAnchor,
                        ZoomSourceAnchorBinding(id: sourceID, reportsPreference: true)
                    )
            case .outerContainer:
                label()
                    .environment(\.zoomSourceAnchor, nil)
            case .childAnchor:
                label()
                    .environment(
                        \.zoomSourceAnchor,
                        ZoomSourceAnchorBinding(id: sourceID, reportsPreference: false)
                    )
            }
        }
        .buttonStyle(.plain)

        Group {
            switch anchorMode {
            case .automatic:
                button
                    .onPreferenceChange(ZoomSourceAnchoredKey.self) { isAnchored = $0 }
                    .modifier(ZoomTransitionSource(
                        id: isAnchored ? AnyHashable(StandDown(id: sourceID)) : AnyHashable(sourceID),
                        cornerRadius: isAnchored ? nil : cornerRadius
                    ))
            case .outerContainer:
                button
                    .modifier(ZoomTransitionSource(
                        id: AnyHashable(sourceID),
                        cornerRadius: cornerRadius
                    ))
            case .childAnchor:
                button
            }
        }
        .disabled(!isEnabled)
    }
}

private struct ZoomSourceAnchor: ViewModifier {
    let cornerRadius: CGFloat?
    @Environment(\.zoomSourceAnchor) private var anchor

    @ViewBuilder
    func body(content: Content) -> some View {
        if let anchor {
            let sourceContent = content
                .modifier(ZoomTransitionSource(
                    id: AnyHashable(anchor.id), cornerRadius: cornerRadius
                ))
                .environment(\.zoomSourceAnchor, nil)
            if anchor.reportsPreference {
                sourceContent
                    .preference(key: ZoomSourceAnchoredKey.self, value: true)
            } else {
                sourceContent
            }
        } else {
            content
        }
    }
}

private struct ZoomTransitionSource: ViewModifier {
    let id: AnyHashable
    let cornerRadius: CGFloat?
    @Environment(\.navigationZoomNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            if let cornerRadius {
                content.matchedTransitionSource(id: id, in: namespace) { source in
                    source
                        .background(.clear)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                content.matchedTransitionSource(id: id, in: namespace) { source in
                    source.background(.clear)
                }
            }
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let sourceID: UUID?
    @Environment(\.navigationZoomNamespace) private var namespace
    @Environment(\.zoomDestinationSuppressed) private var suppressed

    @ViewBuilder
    func body(content: Content) -> some View {
        if let sourceID, let namespace, !suppressed {
            content.navigationTransition(
                .zoom(sourceID: AnyHashable(sourceID), in: namespace)
            )
        } else {
            content
        }
    }
}

extension View {
    /// Marks the platter inside a `ZoomSourceButton`'s label as the zoom origin
    /// so any outer padding on the row is excluded from the transition portal.
    func zoomSourceAnchor(cornerRadius: CGFloat? = VideoCardMetrics.cornerRadius) -> some View {
        modifier(ZoomSourceAnchor(cornerRadius: cornerRadius))
    }

    func zoomDestination(_ source: RouteZoomSource) -> some View {
        modifier(ZoomDestination(sourceID: source.id))
    }
}

extension Route {
    /// The tapped card this route was opened from, whatever the route kind.
    var zoomSourceID: UUID? {
        switch self {
        case .videoDetail(let target): target.zoomSourceID
        case .liveRoom(_, let zoom), .bangumiDetail(_, let zoom), .offlinePlayer(_, let zoom),
             .offlinePager(_, let zoom): zoom.id
        default: nil
        }
    }
}
