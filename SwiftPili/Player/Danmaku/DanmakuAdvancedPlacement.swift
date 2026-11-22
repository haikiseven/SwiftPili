import Foundation

enum DanmakuAdvancedStage {
    static let width: Double = 1280
    static let height: Double = 720
}

struct DanmakuAdvancedPlacement: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var left: Double
        var top: Double
    }

    struct Viewport: Equatable, Sendable {
        var width: Double
        var height: Double
    }

    var start: Point
    var end: Point
    var alphaFrom: Double
    var alphaTo: Double
    var rotZ: Double
    var rotY: Double
    var lifetimeSeconds: Double
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

enum DanmakuAdvancedFontMapping {
    static let fallbackPostScriptName = "PingFangSC-Medium"

    private static let heiti = "PingFangSC-Semibold"
    private static let songti = "STSongti-SC-Regular"
    private static let table: [String: String] = [
        "幼圆": "STYuanti-SC-Regular",
        "微软雅黑": fallbackPostScriptName,
        "Microsoft YaHei": fallbackPostScriptName,
        "\"Microsoft YaHei\"": fallbackPostScriptName,
        "黑体": heiti,
        "SimHei": heiti,
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
