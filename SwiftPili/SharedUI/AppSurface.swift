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

    func appGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(AppGlassSurface(shape: shape, interactive: interactive))
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

    @Environment(\.colorScheme) private var colorScheme
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
                            .overlay(
                                Circle().strokeBorder(
                                    AppStroke.cardBorder(for: colorScheme),
                                    lineWidth: AppStroke.hairlineWidth
                                )
                            )
                    } else if #available(iOS 26.0, *) {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Circle())
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle().strokeBorder(
                                    AppStroke.glassBorder(for: colorScheme),
                                    lineWidth: AppStroke.hairlineWidth
                                )
                            )
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppFill.card, in: shape)
                .overlay(
                    shape
                        .stroke(AppStroke.glassBorder(for: colorScheme), lineWidth: AppStroke.hairlineWidth)
                        .allowsHitTesting(false)
                )
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .stroke(AppStroke.glassBorder(for: colorScheme), lineWidth: AppStroke.hairlineWidth)
                        .allowsHitTesting(false)
                )
        }
    }
}

private struct AppFilterChipSurface: ViewModifier {
    let isSelected: Bool
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule()
                        .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.24 : 0.16) : AppFill.card)
                        .overlay(
                            Capsule().strokeBorder(
                                AppStroke.chipBorder(
                                    isSelected: isSelected,
                                    tint: tint,
                                    colorScheme: colorScheme,
                                    reduceTransparency: true
                                ),
                                lineWidth: AppStroke.hairlineWidth
                            )
                        )
                } else if #available(iOS 26.0, *) {
                    if isSelected {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: Capsule())
                    } else {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                } else {
                    Capsule()
                        .fill(
                            isSelected
                                ? AnyShapeStyle(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                                : AnyShapeStyle(AppFill.inset)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                AppStroke.chipBorder(
                                    isSelected: isSelected,
                                    tint: tint,
                                    colorScheme: colorScheme
                                ),
                                lineWidth: AppStroke.hairlineWidth
                            )
                        )
                }
            }
    }
}

private struct AppSolidChipSurface: ViewModifier {
    let isSelected: Bool
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Capsule()
                        .fill(AppFill.card)
                        .overlay {
                            if isSelected {
                                Capsule().fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.16))
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(
                                AppStroke.chipBorder(
                                    isSelected: isSelected,
                                    tint: tint,
                                    colorScheme: colorScheme,
                                    reduceTransparency: true
                                ),
                                lineWidth: AppStroke.hairlineWidth
                            )
                        )
                } else {
                    Capsule()
                        .fill(
                            isSelected
                                ? tint.opacity(colorScheme == .dark ? 0.20 : 0.13)
                                : AppFill.inset
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                AppStroke.chipBorder(
                                    isSelected: isSelected,
                                    tint: tint,
                                    colorScheme: colorScheme
                                ),
                                lineWidth: AppStroke.hairlineWidth
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch surface {
        case .standard:
            content.background {
                shape
                    .fill(AppFill.card)
                    .overlay(
                        shape.strokeBorder(
                            AppStroke.cardBorder(for: colorScheme, surface: .standard),
                            lineWidth: AppStroke.hairlineWidth
                        )
                    )
            }
        case .cinematic:
            content.background {
                shape
                    .fill(reduceTransparency ? Color(white: 0.11) : Color.white.opacity(0.075))
                    .overlay(
                        shape.strokeBorder(
                            AppStroke.cardBorder(for: colorScheme, surface: .cinematic),
                            lineWidth: AppStroke.hairlineWidth
                        )
                    )
            }
        }
    }
}
