import Foundation

struct DanmakuAdvancedScript: Equatable, Sendable {
    enum Space: Equatable, Sendable {
        case normalized
        case absolutePixels
    }

    struct Coordinate: Equatable, Sendable {
        var value: Double
        var space: Space

        init(value: Double) {
            self.value = value
            self.space = value < 1 ? .normalized : .absolutePixels
        }
    }

    enum WireFlag: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
    }

    var startX: Coordinate
    var startY: Coordinate
    var alphaFrom: Double
    var alphaTo: Double
    var lifetimeSeconds: Double
    var text: String
    var rotZ: Double
    var rotY: Double
    var endX: Coordinate
    var endY: Coordinate
    var moveDurationMilliseconds: Double
    var index10: Double
    var stroke: WireFlag
    var fontName: String
    var index13: WireFlag
    var path: String?

    static func parse(_ content: String) -> DanmakuAdvancedScript? {
        guard let atoms = DanmakuAdvancedScriptDecoding.atoms(from: content) else {
            return nil
        }
        return DanmakuAdvancedScriptDecoding.script(from: atoms)
    }
}

private enum DanmakuAdvancedScriptDecoding {
    enum Atom {
        case string(String)
        case number(Double)
        case flag(DanmakuAdvancedScript.WireFlag)
    }

    static func atoms(from content: String) -> [Atom]? {
        guard let data = content.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard let array = object as? [Any], array.count <= 15 else { return nil }
        var atoms: [Atom] = []
        atoms.reserveCapacity(array.count)
        for value in array {
            guard let atom = atom(from: value) else { return nil }
            atoms.append(atom)
        }
        return atoms
    }

    static func script(from atoms: [Atom]) -> DanmakuAdvancedScript? {
        guard
            let startX = coordinate(0, atoms, ifMissing: 0),
            let startY = coordinate(1, atoms, ifMissing: 0),
            let alpha = alpha(2, atoms),
            let lifetime = number(3, atoms, ifMissing: 0),
            let text = string(4, atoms, ifMissing: ""),
            let rotZ = number(5, atoms, ifMissing: 0),
            let rotY = number(6, atoms, ifMissing: 0),
            let endX = coordinate(7, atoms, ifMissing: 0),
            let endY = coordinate(8, atoms, ifMissing: 0),
            let move = number(9, atoms, ifMissing: 0),
            let index10 = number(10, atoms, ifMissing: 0),
            let stroke = flag(11, atoms, ifMissing: .bool(false)),
            let fontName = string(12, atoms, ifMissing: ""),
            let index13 = flag(13, atoms, ifMissing: .int(0)),
            let path = optionalString(14, atoms)
        else { return nil }
        return DanmakuAdvancedScript(
            startX: startX,
            startY: startY,
            alphaFrom: alpha.from,
            alphaTo: alpha.to,
            lifetimeSeconds: lifetime,
            text: text,
            rotZ: rotZ,
            rotY: rotY,
            endX: endX,
            endY: endY,
            moveDurationMilliseconds: move,
            index10: index10,
            stroke: stroke,
            fontName: fontName,
            index13: index13,
            path: path
        )
    }

    private static func atom(from value: Any) -> Atom? {
        if let text = value as? String {
            return .string(text)
        }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .flag(.bool(number.boolValue))
        }
        let magnitude = number.doubleValue
        guard magnitude.isFinite else { return nil }
        return .number(magnitude)
    }

    private static func coordinate(
        _ index: Int,
        _ atoms: [Atom],
        ifMissing: Double
    ) -> DanmakuAdvancedScript.Coordinate? {
        guard let value = number(index, atoms, ifMissing: ifMissing) else { return nil }
        return DanmakuAdvancedScript.Coordinate(value: value)
    }

    private static func alpha(
        _ index: Int,
        _ atoms: [Atom]
    ) -> (from: Double, to: Double)? {
        guard index < atoms.count else { return (from: 1, to: 1) }
        guard case let .string(raw) = atoms[index] else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard
            let from = finite(String(parts[0])),
            let alphaTo = finite(String(parts[1]))
        else { return nil }
        return (from, alphaTo)
    }

    private static func number(_ index: Int, _ atoms: [Atom], ifMissing: Double) -> Double? {
        guard index < atoms.count else { return ifMissing }
        switch atoms[index] {
        case let .number(value):
            return value
        case let .string(raw):
            return finite(raw)
        case .flag:
            return nil
        }
    }

    private static func finite(_ raw: String) -> Double? {
        guard let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    private static func string(_ index: Int, _ atoms: [Atom], ifMissing: String) -> String? {
        guard index < atoms.count else { return ifMissing }
        guard case let .string(value) = atoms[index] else { return nil }
        return value
    }

    private static func flag(
        _ index: Int,
        _ atoms: [Atom],
        ifMissing: DanmakuAdvancedScript.WireFlag
    ) -> DanmakuAdvancedScript.WireFlag? {
        guard index < atoms.count else { return ifMissing }
        switch atoms[index] {
        case let .flag(flag):
            return flag
        case let .number(value):
            guard let int = Int(exactly: value) else { return nil }
            return .int(int)
        case .string:
            return nil
        }
    }

    private static func optionalString(_ index: Int, _ atoms: [Atom]) -> String?? {
        guard index < atoms.count else { return .some(nil) }
        guard case let .string(value) = atoms[index] else { return nil }
        return .some(value)
    }
}
