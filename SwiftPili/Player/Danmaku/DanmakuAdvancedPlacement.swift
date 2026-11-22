import Foundation

/// 1280×720 absolute-pixel reference stage for Bilibili mode-7 coordinates.
enum DanmakuAdvancedStage {
    static let width: Double = 1280
    static let height: Double = 720
}

/// Where one mode-7 bullet sits, before a layer exists.
///
/// Bilibili mode-7 x/y is the TOP-LEFT of the text, not the layer center.
/// `start` and `end` stay top-left in viewport points. The renderer adds half
/// the raster size when it sets `CALayer.position` (the anchor is the center).
///
/// Index 14 (`path`) is not read. SVG motion is deferred; a path does not move
/// these points.
struct DanmakuAdvancedPlacement: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        /// Distance from the viewport's left edge, in points.
        var left: Double
        /// Distance from the viewport's top edge, in points.
        var top: Double
    }

    /// Viewport or stage, in the same unit the caller uses for both axes.
    struct Viewport: Equatable, Sendable {
        var width: Double
        var height: Double
    }

    /// Top-left at `progress`, in viewport points.
    var start: Point
    /// Top-left at the end of the move, in viewport points.
    var end: Point
    var alphaFrom: Double
    var alphaTo: Double
    /// Degrees, as the script carried them. Radians belong at the render edge.
    var rotZ: Double
    /// Degrees, as the script carried them.
    var rotY: Double
    var lifetimeSeconds: Double
    /// `moveDurationMilliseconds / 1000`, clamped into `0...lifetimeSeconds`.
    /// Zero means the renderer holds `start` for the whole lifetime. `end` is
    /// still the authored point; a zero move does not rewrite it.
    var moveDurationSeconds: Double

    static func place(
        _ script: DanmakuAdvancedScript,
        viewport: Viewport,
        stage: Viewport = Viewport(
            width: DanmakuAdvancedStage.width,
            height: DanmakuAdvancedStage.height
        )
    ) -> DanmakuAdvancedPlacement {
        let lifetime = carriedLifetime(script.lifetimeSeconds)
        return DanmakuAdvancedPlacement(
            start: point(horizontal: script.startX, vertical: script.startY, viewport: viewport, stage: stage),
            end: point(horizontal: script.endX, vertical: script.endY, viewport: viewport, stage: stage),
            alphaFrom: script.alphaFrom,
            alphaTo: script.alphaTo,
            rotZ: script.rotZ,
            rotY: script.rotY,
            lifetimeSeconds: lifetime,
            moveDurationSeconds: clampedMove(script.moveDurationMilliseconds, lifetime: lifetime)
        )
    }

    /// One axis of the scale rule. No viewport I/O.
    ///
    /// - `value < 1` (`.normalized`): `value * viewportAxis`
    /// - `value >= 1` (`.absolutePixels`, including exactly 1): `value * viewportAxis / stageAxis`
    ///
    /// Each axis is independent, so the same script keeps the same fraction of
    /// every viewport — inline and fullscreen — including a viewport whose
    /// aspect is not the stage's.
    static func axis(
        _ coordinate: DanmakuAdvancedScript.Coordinate,
        viewportAxis: Double,
        stageAxis: Double
    ) -> Double {
        switch coordinate.space {
        case .normalized:
            return coordinate.value * viewportAxis
        case .absolutePixels:
            let stage = stageAxis > 0 ? stageAxis : 1
            return coordinate.value * viewportAxis / stage
        }
    }

    private static func point(
        horizontal: DanmakuAdvancedScript.Coordinate,
        vertical: DanmakuAdvancedScript.Coordinate,
        viewport: Viewport,
        stage: Viewport
    ) -> Point {
        Point(
            left: axis(horizontal, viewportAxis: viewport.width, stageAxis: stage.width),
            top: axis(vertical, viewportAxis: viewport.height, stageAxis: stage.height)
        )
    }

    private static func carriedLifetime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private static func clampedMove(_ milliseconds: Double, lifetime: Double) -> Double {
        guard milliseconds.isFinite else { return 0 }
        let seconds = max(0, milliseconds) / Double(1000)
        return min(seconds, max(0, lifetime))
    }
}

/// Wire font name → iOS PostScript name. Data, not a `UIFont` lookup.
///
/// The census names are Windows faces this phone does not ship. Each row is the
/// closest face that does: 圆体 for 幼圆, 楷体, 宋体, and PingFang SC for the
/// gothic names (微软雅黑 / 黑体). An unknown or empty string is PingFang SC,
/// the same face scroll bullets already rasterize — never the wire string,
/// because Core Text would miss "幼圆" and fall back to Helvetica, which has
/// no CJK.
enum DanmakuAdvancedFontMapping {
    static let fallbackPostScriptName = "PingFangSC-Medium"

    private static let heiti = "PingFangSC-Semibold"
    private static let songti = "STSongti-SC-Regular"
    private static let table: [String: String] = [
        "幼圆": "STYuanti-SC-Regular",
        "微软雅黑": fallbackPostScriptName,
        "Microsoft YaHei": fallbackPostScriptName,
        // Census stored the quote characters as part of the name (68 rows).
        "\"Microsoft YaHei\"": fallbackPostScriptName,
        "黑体": heiti,
        "SimHei": heiti,
        // Census comma-joined face. The first name is the one that was drawn.
        "SimHei, \"Microsoft JhengHei\"": heiti,
        "楷体": "STKaitiSC-Regular",
        "宋体": songti,
        "SimSun": songti,
        "NSimSun": songti,
    ]

    static func postScriptName(for wireName: String) -> String {
        table[wireName] ?? fallbackPostScriptName
    }
}

/// Index 11, as a stroke switch. JSON `true` and JSON `1` are on. Absence
/// (the parser's `.bool(false)`), JSON `false`, and JSON `0` are off. Any
/// other int is off — the census only ever sent `true` and `1`.
enum DanmakuAdvancedStroke {
    static func isEnabled(_ flag: DanmakuAdvancedScript.WireFlag) -> Bool {
        switch flag {
        case .bool(true), .int(1):
            return true
        case .bool(false), .int:
            return false
        }
    }
}
