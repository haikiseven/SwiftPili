import Foundation

/// One mode-7 bullet, parsed out of its `content` string.
///
/// Mode 7 `content` is a JSON array. The index map below is the 2026-09-22
/// census of `oid=1176840`, `segment_index=1` — 862 items, arity 14 (861) and
/// arity 15 (1), zero JSON failures — written down in
/// `research/mode7-field-census-2026-09-22.md`. It is not a blog's field list.
/// design.md §6 marked index 7 as `起x?`; the captured rows settle it. Index 0/1
/// are the start, index 7/8 are the end:
///
///     [0.99, 0.35, …, 0,    0.35, …]   y fixed, x 0.99 → 0
///     [0.4,  0.01, …, 0.4,  0.99, …]   x fixed, y 0.01 → 0.99
///
/// Index 3 (seconds the item lives) and index 9 (milliseconds it spends moving)
/// are different quantities. The second sample is 4.5s and 1600ms.
///
///     0 startX          5 rotZ         10 unnamed number (`index10`)
///     1 startY          6 rotY         11 stroke (JSON true, or JSON 1)
///     2 "from-to" alpha 7 endX         12 font name, verbatim
///     3 lifetime, sec   8 endY         13 unnamed flag (`index13`)
///     4 text            9 move, ms     14 path string, arity 15 only
///
/// A missing element takes the zero default. A value of the wrong type — or an
/// array longer than 15, which this census never saw — drops the WHOLE item.
/// Returning a script with the bad field blanked would be the half-parse the
/// design forbids.
///
/// Coordinates are classified and nothing more: `< 1` is a fraction of the
/// player, `>= 1` (including exactly 1) is a raw pixel count. This type does
/// not know the viewport, and `fontName` is not a resolved font.
struct DanmakuAdvancedScript: Equatable, Sendable {
    /// `value < 1` is a fraction of the player, so `0` is normalized and a
    /// negative (none in the census) would be too. `value >= 1`, including
    /// exactly `1`, is a raw pixel count. Three rows have a start x of exactly
    /// 1; those are pixels, not "100%". Nested beside `Coordinate` rather than
    /// inside it — a second nesting level is a lint violation, and this is not
    /// a view type that needs to hide the enum.
    enum Space: Equatable, Sendable {
        case normalized
        case absolutePixels
    }

    /// Where a coordinate sits, before any viewport is applied.
    struct Coordinate: Equatable, Sendable {
        var value: Double
        var space: Space

        init(value: Double) {
            self.value = value
            self.space = value < 1 ? .normalized : .absolutePixels
        }
    }

    /// A JSON bool and a JSON int, kept as different tokens.
    ///
    /// Index 11 is `true` (605) or `1` (257). Index 13 is `1` (647), `true`
    /// (167), or `0` (48). `NSNumber` bridges `0` and `1` to `Bool`, so a
    /// cast would erase a split the wire actually uses. See the census.
    enum WireFlag: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
    }

    var startX: Coordinate
    var startY: Coordinate
    /// Index 2, the left of `"from-to"`. Every census row was that string;
    /// a bare number is the wrong type and fails the item.
    var alphaFrom: Double
    var alphaTo: Double
    /// Index 3, seconds. Not the move duration.
    var lifetimeSeconds: Double
    var text: String
    /// Index 5, degrees, as carried. Not converted to radians.
    var rotZ: Double
    /// Index 6, degrees, as carried.
    var rotY: Double
    var endX: Coordinate
    var endY: Coordinate
    /// Index 9, milliseconds. `0` occurred (as the string `"0"`).
    var moveDurationMilliseconds: Double
    /// Index 10. Observed `0`, `200`, `1000` only, sometimes quoted. Unnamed.
    var index10: Double
    /// Index 11. Absence defaults to `.bool(false)`; the census itself never
    /// sent an "off" token, only `true` and `1`.
    var stroke: WireFlag
    /// Index 12, the wire string. Includes quote characters when the wire had
    /// them (`"Microsoft YaHei"`) and comma-joined names. Not a `UIFont`.
    var fontName: String
    /// Index 13. Observed `0`, `1`, and `true`. Unnamed. Absence defaults to
    /// `.int(0)`, which is the "off" token the census actually used — JSON
    /// `false` never appeared.
    var index13: WireFlag
    /// Index 14. The one arity-15 row carried an SVG-like path. Absence is
    /// nil, not an empty path.
    var path: String?

    /// `content` of one mode-7 element. `nil` means the whole bullet is dropped.
    static func parse(_ content: String) -> DanmakuAdvancedScript? {
        guard let atoms = DanmakuAdvancedScriptDecoding.atoms(from: content) else {
            return nil
        }
        return DanmakuAdvancedScriptDecoding.script(from: atoms)
    }
}

/// JSON-array decoding for `DanmakuAdvancedScript.parse`.
///
/// Split out of the value type so the type stays a parsed result. Every
/// function here is total: a wrong token returns nil instead of a default,
/// and only a MISSING token (array shorter than the index) returns a default.
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
        // Longer than 15 was not in the census. Ignoring the tail would keep
        // a script whose new field we had thrown away — a half-parse.
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
        // `as? Bool` is wrong here: NSNumber 0 and 1 bridge to Bool, and the
        // census uses both JSON `true` and JSON `1` as different tokens.
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

    /// `"1-1"`, `"1-0"`, `"1-0.5"`, `"0.5-1"` — the only four strings in the
    /// census. A missing index defaults to fully opaque, which is also what
    /// `"1-1"` means. A present value that is not `number-number` fails.
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
            // Quoted numbers are real: `"0.53"`, `"500"`, `"0"`. A non-numeric
            // string is the wrong type, not a missing field.
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
            // `Int(someDouble)` traps on an out-of-range magnitude. `exactly`
            // returns nil instead, and also rejects `1.5`.
            guard let int = Int(exactly: value) else { return nil }
            return .int(int)
        case .string:
            return nil
        }
    }

    /// One level of optional: outer nil is "wrong type", inner nil is "absent".
    private static func optionalString(_ index: Int, _ atoms: [Atom]) -> String?? {
        guard index < atoms.count else { return .some(nil) }
        guard case let .string(value) = atoms[index] else { return nil }
        return .some(value)
    }
}
