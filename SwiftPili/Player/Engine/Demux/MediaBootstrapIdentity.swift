/// Opaque identity of an actually selected Demand asset and representation.
/// No URL, quality fallback, parser state or playback authority is implied.
struct MediaBootstrapIdentity: Hashable, Sendable {
    let asset: String
    let track: MediaTrackKind
    let representation: String

    // String equality otherwise permits distinct Unicode encodings to compare
    // equal. Selection/config identities must match their original bytes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.track == rhs.track && lhs.asset.utf8.elementsEqual(rhs.asset.utf8) &&
            lhs.representation.utf8.elementsEqual(rhs.representation.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(track)
        hasher.combine(asset.utf8.count)
        for byte in asset.utf8 { hasher.combine(byte) }
        hasher.combine(representation.utf8.count)
        for byte in representation.utf8 { hasher.combine(byte) }
    }
}
