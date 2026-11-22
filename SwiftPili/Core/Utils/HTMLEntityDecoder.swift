import Foundation

/// Single-pass HTML entity decoder for the small, deliberate set bilibili's
/// web APIs are observed to emit inside otherwise-plain JSON string fields
/// (search result titles highlighted with `<em>`, comment `message` text,
/// read-page article HTML). Shared by every site that used to hand-roll its
/// own `replacingOccurrences` chain, so the decoding rules — and their bugs —
/// exist in exactly one place.
///
/// Scans the source once, left to right: ordinary characters are copied
/// verbatim, and each `&` is tested for a well-formed named or numeric
/// entity. A match emits the decoded scalar and the scan resumes just past
/// the terminating `;`; anything else (unknown name, malformed digits,
/// missing `;`, a bare trailing `&`) is left exactly as written. A single
/// left-to-right pass makes double-decoding structurally impossible: once a
/// scalar has been emitted into the output it is never re-scanned, so
/// `&amp;lt;` decodes to the literal text `&lt;`, not `<`.
enum HTMLEntityDecoder {
    /// Named entities this decoder recognizes. Deliberately small — not the
    /// full HTML5 named-entity table — because this is the complete set
    /// bilibili's APIs are known to produce.
    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        // U+00A0 NO-BREAK SPACE, not ASCII space: `&nbsp;` marks a run of
        // non-collapsing spacing in the source markup, and decoding it to a
        // real nbsp keeps that intent (no line break inside the run) rather
        // than silently downgrading it to an ordinary, collapsible space.
        "nbsp": "\u{00A0}"
    ]

    /// Longest name above, so a malformed/unknown `&somethingverylong;` is
    /// rejected after a bounded number of characters rather than scanning
    /// to the next `;` anywhere in the rest of the string.
    private static let maxNamedEntityLength = namedEntities.keys.map(\.count).max() ?? 0

    /// Decodes every recognized entity in `raw`. Cheap no-op for the common
    /// case of a string with no `&` at all.
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
                // Not a recognized/well-formed entity: emit the `&` literally
                // and resume scanning right after it, so the rest of the
                // malformed sequence is read as ordinary text (never
                // double-decoded, never dropped).
                output.append(scalar)
                index = scalars.index(after: index)
            }
        }
        return String(output)
    }

    /// Attempts to decode one entity starting at `start` (the `&`). Returns
    /// the decoded scalar and the index just past the terminating `;` on
    /// success, or nil when the text at `start` is not a recognized,
    /// well-formed entity.
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
                // A numeric entity has no legitimate reason to run long;
                // bail rather than scan arbitrarily far for a ';'.
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
