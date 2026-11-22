import Kingfisher
import SwiftUI

enum ImageCoverShape: Equatable {
    case rect
    case roundedRect(CGFloat)
    case circle

    @ViewBuilder
    func ground(_ color: Color) -> some View {
        switch self {
        case .rect:
            Rectangle().fill(color)
        case let .roundedRect(radius):
            RoundedRectangle(cornerRadius: radius).fill(color)
        case .circle:
            Circle().fill(color)
        }
    }
}

extension KFImageProtocol {
    @ViewBuilder
    func imageLoadingCover(
        shape: ImageCoverShape = .rect,
        ground: Color = .imagePlaceholderOpaque,
        shorterSide: CGFloat? = nil,
        tint: Color? = nil,
        showsIndicator: Bool? = nil,
        isHidden: Binding<Bool>? = nil
    ) -> some View {
        let resolvedShowsIndicator = showsIndicator ?? (isHidden != nil)
        if !resolvedShowsIndicator, ground == .clear, isHidden == nil {
            onFailureView {
                FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
            }
        } else {
            placeholder {
                if let isHidden {
                    ImageLoadingCoverGate(
                        isHidden: isHidden,
                        content: LoadingCover(
                            shape: shape,
                            ground: ground,
                            shorterSide: shorterSide,
                            tint: tint,
                            showsIndicator: resolvedShowsIndicator
                        )
                    )
                } else {
                    LoadingCover(
                        shape: shape,
                        ground: ground,
                        shorterSide: shorterSide,
                        tint: tint,
                        showsIndicator: resolvedShowsIndicator
                    )
                }
            }
            .onFailureView {
                if let isHidden {
                    ImageLoadingCoverGate(
                        isHidden: isHidden,
                        content: FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
                    )
                } else {
                    FailedCover(shape: shape, ground: ground, shorterSide: shorterSide, tint: tint)
                }
            }
            .background {
                if ground != .clear { shape.ground(ground) }
            }
        }
    }
}

private struct ImageLoadingCoverGate<Content: View>: View {
    @Binding var isHidden: Bool
    let content: Content

    var body: some View {
        if !isHidden { content }
    }
}

extension KFOptionSetter {
    func imageFadePolicy(reduceMotion: Bool) -> Self {
        guard let seconds = ImagePipelinePolicy.fadeSeconds(reduceMotion: reduceMotion) else {
            options.transition = .none
            return self
        }
        options.transition = .fade(seconds)
        return self
    }
}

enum ImageLoadingIndicatorPolicy {
    static let staticIndicatorKey = "image_loading_indicator_static"

    nonisolated(unsafe) static var isStatic = false

    @MainActor
    static func applyExperimentalPolicy() {
        isStatic = ExperimentalSettingsPolicy.isAllowed(.diagnostics)
            && UserDefaults.standard.bool(forKey: staticIndicatorKey)
    }

    @MainActor
    static func setStatic(_ on: Bool) {
        guard ExperimentalSettingsPolicy.isAllowed(.diagnostics) else { return }
        UserDefaults.standard.set(on, forKey: staticIndicatorKey)
        applyExperimentalPolicy()
    }
}

struct LoadingCover: View {
    let shape: ImageCoverShape
    var ground: Color = .imagePlaceholderOpaque
    var shorterSide: CGFloat?
    var tint: Color?
    var showsIndicator: Bool = true

    private static let spinnerMinSide: CGFloat = 28

    private static let spinnerDelay = Duration.milliseconds(200)

    @State private var spinnerVisible = false

    private var allowsSpinner: Bool {
        guard showsIndicator else { return false }
        guard let shorterSide else { return true }
        return shorterSide >= Self.spinnerMinSide
    }

    var body: some View {
        if allowsSpinner {
            gated
        } else {
            shape.ground(ground).accessibilityHidden(true)
        }
    }

    private var gated: some View {
        ZStack {
            shape.ground(ground)
            if spinnerVisible { indicator }
        }
        .task {
            try? await Task.sleep(for: Self.spinnerDelay)
            guard !Task.isCancelled else { return }
            ImageDiagnostics.noteIndicatorShown(shorterSide: shorterSide)
            spinnerVisible = true
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicator: some View {
        let indicatorTint = tint ?? Color.biliAccent
        if ImageLoadingIndicatorPolicy.isStatic {
            Image(systemName: "circle.dashed")
                .font(.title3.weight(.light))
                .foregroundStyle(indicatorTint)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(indicatorTint)
        }
    }
}

struct FailedCover: View {
    let shape: ImageCoverShape
    var ground: Color = .imagePlaceholderOpaque
    var shorterSide: CGFloat?
    var tint: Color?

    private var glyph: String {
        if case .circle = shape { "person.fill" } else { "photo" }
    }

    private var glyphSize: CGFloat {
        min(26, max(9, (shorterSide ?? 56) * 0.42))
    }

    var body: some View {
        ZStack {
            shape.ground(ground)
            Image(systemName: glyph)
                .resizable()
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                .foregroundStyle(tint ?? .secondary)
        }
        .accessibilityHidden(true)
    }
}
