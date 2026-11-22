import Foundation

enum HTMLEntityDecoder {
    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}"
    ]

    private static let maxNamedEntityLength = namedEntities.keys.map(\.count).max() ?? 0

    static func decode(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        let scalars = raw.unicodeScalars
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar == "&" else {
                output.append(scalar)
                index = scalars.index(after: index)
                continue
            }
            if let (decoded, next) = decodeEntity(scalars, from: index) {
                output.append(decoded)
                index = next
            } else {
                output.append(scalar)
                index = scalars.index(after: index)
            }
        }
        return String(output)
    }

    private static func decodeEntity(
        _ scalars: String.UnicodeScalarView,
        from start: String.UnicodeScalarView.Index
    ) -> (Unicode.Scalar, String.UnicodeScalarView.Index)? {
        var index = scalars.index(after: start)
        guard index < scalars.endIndex else { return nil }

        if scalars[index] == "#" {
            index = scalars.index(after: index)
            guard index < scalars.endIndex else { return nil }
            let isHex = scalars[index] == "x" || scalars[index] == "X"
            if isHex {
                index = scalars.index(after: index)
            }
            var digits = ""
            while index < scalars.endIndex, scalars[index] != ";" {
                guard digits.count < 8 else { return nil }
                digits.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
            }
            guard index < scalars.endIndex, !digits.isEmpty else { return nil }
            let value = isHex ? UInt32(digits, radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar, scalars.index(after: index))
        }

        var name = ""
        while index < scalars.endIndex, scalars[index] != ";", name.count <= maxNamedEntityLength {
            name.unicodeScalars.append(scalars[index])
            index = scalars.index(after: index)
        }
        guard index < scalars.endIndex, scalars[index] == ";", let scalar = namedEntities[name] else {
            return nil
        }
        return (scalar, scalars.index(after: index))
    }
}
