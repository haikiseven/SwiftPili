import SwiftUI

/// What kind of page a view is drawn on.
///
/// Watching pages (VOD detail, and in time bangumi, live, music) are
/// `.cinematic`: always dark, lit by the content's artwork, with glass cards.
/// Browsing pages are `.standard` and follow the system appearance. A page
/// declares this once at its root with `appSurface(_:)`; shared components read
/// it, so no call site chooses a card style of its own.
enum AppSurface: Sendable {
    case standard
    case cinematic
}

private struct AppSurfaceKey: EnvironmentKey {
    static let defaultValue: AppSurface = .standard
}

extension EnvironmentValues {
    var appSurface: AppSurface {
        get { self[AppSurfaceKey.self] }
        set { self[AppSurfaceKey.self] = newValue }
    }
}

extension View {
    /// Declares the page's surface. `.cinematic` also forces the dark scheme
    /// for everything below this call, which is the one place a page should
    /// set it. Presentations attached ABOVE the call (a page's sheets, when the
    /// call sits on its content) keep the system appearance and `.standard`.
    @ViewBuilder
    func appSurface(_ surface: AppSurface) -> some View {
        switch surface {
        case .standard:
            environment(\.appSurface, .standard)
        case .cinematic:
            environment(\.appSurface, .cinematic)
                .environment(\.colorScheme, .dark)
        }
    }

    /// A card's background: a flat, translucent fill with no stroke, gradient
    /// or shadow on a standard page, or Liquid Glass on a cinematic watching
    /// page. Video/live cards don't use this at all — they are bare
    /// everywhere (`videoCardSurface()`); this is for the other cards a
    /// standard page still backs, such as moment cards and stat bars.
    func appCardSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(AppCardSurface(shape: shape))
    }

    /// Unified ambient browse background shared across all standard browsing
    /// screens (Home, Dynamics, Live, Mine, Settings, Favorites, UserSpace) —
    /// one neutral base lit by a large, soft `MeshGradient` of glows derived
    /// from the user's accent, so no tab's background drifts to a hue of its
    /// own and every page reads as one app. Adapts automatically between dark
    /// and light appearance.
    func appAmbientBrowseBackground() -> some View {
        background {
            AppAmbientBrowseBackdrop()
                .ignoresSafeArea()
        }
    }

    /// Floating glass for chrome that sits over content — Liquid Glass on
    /// iOS 26, a thin material with a hairline before it (the same fallback
    /// `launcherGlass` uses). Valid on either surface.
    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    /// Filter-chip surface aligned with HIG Materials & Reduce Transparency:
    /// uses Liquid Glass on iOS 26+ (tinted gently when selected) and crisp
    /// semantic fills when Reduce Transparency is enabled or pre-26.
    func appFilterChipSurface(isSelected: Bool, tint: Color = .biliAccent) -> some View {
        modifier(AppFilterChipSurface(isSelected: isSelected, tint: tint))
    }

    /// Solid semantic pill surface for inline chips and tag rows inside scroll
    /// content or sheets, avoiding Liquid Glass on content surfaces.
    func appSolidChipSurface(isSelected: Bool, tint: Color = .biliAccent) -> some View {
        modifier(AppSolidChipSurface(isSelected: isSelected, tint: tint))
    }
}

/// Shared 44×44 pt top-bar circular action button using Liquid Glass on iOS 26+.
struct AppTopBarCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background {
                    if reduceTransparency {
                        Circle()
                            .fill(AppFill.card)
                            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                    } else if #available(iOS 26.0, *) {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Circle())
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppFilterChipSurface: ViewModifier {
    let isSelected: Bool
    let tint: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule()
                        .fill(isSelected ? tint.opacity(0.18) : AppFill.card)
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? tint.opacity(0.4) : Color.primary.opacity(0.12),
                                lineWidth: 0.5
                            )
                        )
                } else if #available(iOS 26.0, *) {
                    if isSelected {
                        Capsule()
                            .fill(tint.opacity(0.18))
                            .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: Capsule())
                    } else {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                } else {
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(AppFill.inset))
                }
            }
    }
}

private struct AppSolidChipSurface: ViewModifier {
    let isSelected: Bool
    let tint: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule()
                        .fill(AppFill.card)
                        .overlay {
                            if isSelected {
                                Capsule().fill(tint.opacity(0.18))
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? tint.opacity(0.48) : Color.primary.opacity(0.16),
                                lineWidth: 0.5
                            )
                        )
                } else {
                    Capsule()
                        .fill(isSelected ? tint.opacity(0.14) : AppFill.inset)
                        .overlay(
                            Capsule().strokeBorder(
                                isSelected ? tint.opacity(0.38) : Color.primary.opacity(0.10),
                                lineWidth: 0.5
                            )
                        )
                }
            }
    }
}

/// Neutral system grouped canvas shared across standard browsing screens so
/// navigation chrome, grouped cards, and profile avatars sit over a clean
/// native surface without an artificial top-leading accent gradient wash.
private struct AppAmbientBrowseBackdrop: View {
    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct AppCardSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.appSurface) private var surface
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch surface {
        case .standard:
            // Flat and translucent: no stroke, no gradient, no shadow. The
            // ambient backdrop behind the page is what should read as lit —
            // a card on top of it stays a quiet, barely-there surface.
            content.background {
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
            }
        case .cinematic:
            // HIG § Materials: keep inline content cards on a quiet, native
            // dark content surface rather than wrapping content in Liquid Glass.
            content.background {
                shape.fill(Color.white.opacity(0.065))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}
