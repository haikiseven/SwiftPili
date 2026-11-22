import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synchronous actor-isolated bootstrap operations. No await separates the
/// HTTP/version check from byte retirement, owned copying or registration.
extension MediaByteRangeStore {
    struct BootstrapRecord {
        let key: Key
        let entryVersion: UUID
        let provenance: MediaHTTPBootstrapProvenance
        var lastUse: UInt64
    }

    /// Fresh HTTP evidence and its complete owned prefix are resolved in one
    /// actor operation. A coverage snapshot followed by another hop is unsafe.
    /// A hit preserves the real response kind, total and type; it adds no wire
    /// bytes and grants no parser, decoder or playback readiness authority.
    func retainedBootstrap(
        identity: MediaBootstrapIdentity?, url: URL, headers: [String: String],
        count: Int, now: Date = Date()
    ) -> PathAHTTPMediaSource.InitialHead? {
        guard let identity, count > 0, let requested = Int64(exactly: count),
              var record = bootstrapRecords[identity] else { return nil }
        guard let entry = entry(for: record.key), entry.bootstrapVersion == record.entryVersion else {
            bootstrapRecords[identity] = nil
            return nil
        }
        // Expired records cannot skip the GET. The entry's separate comparison
        // baseline preserves byte-version authority beyond this roster.
        guard record.provenance.freshness.isFresh(at: now) else { return nil }
        guard record.provenance.matches(url: url, headers: headers) else { return nil }
        let needed = min(requested, record.key.contentLength)
        guard needed <= record.provenance.returnedRange.upperBound,
              let byteCount = Int(exactly: needed),
              let data = entry.copyPrefix(offset: 0, count: byteCount), data.count == byteCount else { return nil }
        record.lastUse = tick()
        bootstrapRecords[identity] = record
        entries[record.key.path]?.lastUse = record.lastUse
        return PathAHTTPMediaSource.InitialHead(
            data: data, info: record.provenance.info, responseKind: record.provenance.responseKind
        )
    }

    /// Register only an actually fetched, validated head already held under
    /// today's store version. Failed/new non-reusable responses retire older
    /// evidence for this path even without a selection or proven length.
    func retainBootstrap(identity: MediaBootstrapIdentity?, registration: MediaHTTPBootstrapRegistration) {
        let url = registration.url
        let headers = registration.headers
        let response = registration.response
        let requestStart = registration.requestStart
        let receivedAt = registration.receivedAt
        let head = registration.head
        if let path = Key.networkPath(for: url) {
            observeBootstrapResponse(path: path, identity: identity, url: url, response: response, head: head)
        }
        guard let identity else { return }
        bootstrapRecords[identity] = nil
        guard !identity.asset.isEmpty, !identity.representation.isEmpty,
              let provenance = MediaHTTPBootstrapProvenance(
                url: url, headers: headers, response: response,
                requestStart: requestStart, receivedAt: receivedAt, head: head
              ),
              let total = head.info.contentLength,
              let key = Key.key(for: url, contentLength: total),
              let entry = entry(for: key),
              let held = entry.copyPrefix(offset: 0, count: head.data.count), held == head.data else { return }
        // One canonical entry keeps only the latest actual head's authority.
        bootstrapRecords[identity] = BootstrapRecord(
            key: key, entryVersion: entry.bootstrapVersion, provenance: provenance, lastUse: tick()
        )
        if bootstrapRecords.count > Self.bootstrapRecordLimit,
           let oldest = bootstrapRecords.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            bootstrapRecords[oldest] = nil
        }
    }

    func invalidateBootstrap(path: String) {
        bootstrapRecords = bootstrapRecords.filter { $0.value.key.path != path }
    }

    private func observeBootstrapResponse(
        path: String, identity: MediaBootstrapIdentity?, url: URL, response: HTTPURLResponse,
        head: PathAHTTPMediaSource.InitialHead
    ) {
        let previous = entries[path]?.bootstrapBaseline
        let changed = previous?.hasChanged(identity: identity, response: response, info: head.info) ?? false
        if changed {
            revokeResidentEntry(at: path)
            entries[path] = nil
            // Only today's fetched prefix is authoritative after a known
            // version change. Existing budgets still govern readmission.
            if let total = head.info.contentLength, let key = Key.key(for: url, contentLength: total) {
                admit(key, offset: 0, data: head.data)
            }
        }
        invalidateBootstrap(path: path)
        // Nil identity never creates a pristine baseline, and never forgets
        // the last selected identity or present validators of surviving bytes.
        let selected = identity.flatMap { value in
            !value.asset.isEmpty && !value.representation.isEmpty ? value : nil
        } ?? previous?.identity
        guard let selected, !head.data.isEmpty,
              let total = head.info.contentLength, let key = Key.key(for: url, contentLength: total),
              let entry = entry(for: key), entry.agrees(with: head.data, at: 0) else { return }
        entries[path]?.bootstrapBaseline = MediaHTTPBootstrapVersionBaseline(
            identity: selected, response: response, info: head.info, previous: changed ? nil : previous
        )
    }
}
