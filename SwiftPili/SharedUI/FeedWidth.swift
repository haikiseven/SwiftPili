import SwiftUI

extension View {
    func measuringContentWidth(into width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { measured in
            guard measured > 0, abs(width.wrappedValue - measured) > 0.5 else { return }
            width.wrappedValue = measured
        }
    }
}

enum FormSurface {
    case grouped
    case plain
    case ambientBrowse
}

extension View {
    @ViewBuilder
    func readableFormWidth(_ surface: FormSurface = .ambientBrowse) -> some View {
        switch surface {
        case .grouped:
            readableFormColumn()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        case .plain:
            readableFormColumn()
                .background(Color(.systemBackground).ignoresSafeArea())
        case .ambientBrowse:
            scrollContentBackground(.hidden)
                .readableFormColumn()
                .appAmbientBrowseBackground()
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: SettingsScaffoldingMetrics.floatingTabBarClearance)
                }
        }
    }

    private func readableFormColumn() -> some View {
        frame(maxWidth: ReadableWidth.form)
            .frame(maxWidth: .infinity)
    }
}

enum SettingsScaffoldingMetrics {
    static let floatingTabBarClearance: CGFloat = 58
}

enum FeedWidth {
    @MainActor
    static var seed: CGFloat {
        let width = windowWidth
        return max(0, width - FeedColumnPolicy.horizontalMargin(for: width) * 2)
    }

    @MainActor
    static var fullContainerSeed: CGFloat {
        windowWidth
    }

    @MainActor
    static func fullContainerSeed(cappedTo limit: CGFloat) -> CGFloat {
        min(fullContainerSeed, max(0, limit))
    }

    @MainActor
    private static var windowWidth: CGFloat {
        if let frame = AppWindowMetrics.frameInScreen, frame.width > 0 { return frame.width }
        return WindowMetricsFallback.currentWidth
    }
}

struct LibraryRowLayout<Content: View>: View {
    @State private var contentWidth: CGFloat = FeedWidth.fullContainerSeed
    @ViewBuilder var content: () -> Content

    private static var columnSpacing: CGFloat { 0 }

    private var columns: [GridItem] {
        let count = FeedColumnPolicy.columnCount(.videoRow, availableWidth: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top),
            count: count
        )
    }

    private var columnWidth: CGFloat {
        FeedColumnPolicy.columnWidth(
            availableWidth: contentWidth,
            count: columns.count,
            spacing: Self.columnSpacing
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            content()
        }
        .measuringContentWidth(into: $contentWidth)
        .rowCardColumnWidth(columnWidth)
    }
}

private struct RowCardColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var rowCardColumnWidth: CGFloat? {
        get { self[RowCardColumnWidthKey.self] }
        set { self[RowCardColumnWidthKey.self] = newValue }
    }
}

struct RowCardColumnWidthReader<Content: View>: View {
    @Environment(\.rowCardColumnWidth) private var columnWidth
    @ViewBuilder var content: (CGFloat?) -> Content

    var body: some View {
        content(columnWidth)
    }
}

extension View {
    func rowCardColumnWidth(_ width: CGFloat?) -> some View {
        environment(\.rowCardColumnWidth, width)
    }
}

extension Font {
    static func app(_ style: AppTextStyle) -> Font {
        switch style {
        case .title1: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .body: .body
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let role: AppTextRole
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.app(AppTypeScale.style(role, isRegularWidth: sizeClass == .regular))
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func appFont(_ role: AppTextRole, monospacedDigit: Bool = false) -> some View {
        modifier(AppFontModifier(role: role, monospacedDigit: monospacedDigit))
    }
}
