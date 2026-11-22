import SwiftUI

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
    var navigationZoomNamespace: Namespace.ID? {
        get { self[NavigationZoomNamespaceKey.self] }
        set { self[NavigationZoomNamespaceKey.self] = newValue }
    }

    fileprivate var zoomSourceAnchor: ZoomSourceAnchorBinding? {
        get { self[ZoomSourceAnchorKey.self] }
        set { self[ZoomSourceAnchorKey.self] = newValue }
    }

    var zoomDestinationSuppressed: Bool {
        get { self[ZoomDestinationSuppressedKey.self] }
        set { self[ZoomDestinationSuppressedKey.self] = newValue }
    }
}

enum ZoomSourceBindingMode: Sendable {
    case automatic
    case outerContainer
    case childAnchor
}

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
    func zoomSourceAnchor(cornerRadius: CGFloat? = VideoCardMetrics.cornerRadius) -> some View {
        modifier(ZoomSourceAnchor(cornerRadius: cornerRadius))
    }

    func zoomDestination(_ source: RouteZoomSource) -> some View {
        modifier(ZoomDestination(sourceID: source.id))
    }
}

extension Route {
    var zoomSourceID: UUID? {
        switch self {
        case .videoDetail(let target): target.zoomSourceID
        case .liveRoom(_, let zoom), .bangumiDetail(_, let zoom), .offlinePlayer(_, let zoom),
             .offlinePager(_, let zoom): zoom.id
        default: nil
        }
    }
}
