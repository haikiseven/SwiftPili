import SwiftUI

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

    func appCardSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(AppCardSurface(shape: shape))
    }

    func appAmbientBrowseBackground() -> some View {
        background {
            AppAmbientBrowseBackdrop()
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }

    func appFilterChipSurface(isSelected: Bool, tint: Color = .biliAccent) -> some View {
        modifier(AppFilterChipSurface(isSelected: isSelected, tint: tint))
    }

    func appSolidChipSurface(isSelected: Bool, tint: Color = .biliAccent) -> some View {
        modifier(AppSolidChipSurface(isSelected: isSelected, tint: tint))
    }
}

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
            content.background {
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
            }
        case .cinematic:
            content.background {
                shape.fill(Color.white.opacity(0.065))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}
