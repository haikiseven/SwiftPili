import Foundation
import QuartzCore

/// Independent metadata and special-danmaku package owner; never blocks the ordinary segment admit cursor.
@MainActor
final class DanmakuMetadataStore {
    private(set) var metadata: DanmakuMetadata?
    private(set) var packages: [URL: DanmakuTimeIndex] = [:]
    private(set) var metadataFailure: DanmakuSegmentFailureState?
    private(set) var packageFailures: [URL: DanmakuSegmentFailureState] = [:]
    var onMetadata: ((DanmakuMetadata) -> Void)?
    var onSpecialLoaded: (() -> Void)?

    private var oid: Int?
    private var serial: UInt64 = 0
    private var metadataTask: (serial: UInt64, task: Task<Void, Never>)?
    private var packageTasks: [URL: (serial: UInt64, task: Task<Void, Never>)] = [:]

    init() {}

    func reset(oid: Int?) {
        suspend()
        self.oid = oid
        metadata = nil
        packages.removeAll()
        metadataFailure = nil
        packageFailures.removeAll()
    }

    func suspend() {
        serial &+= 1
        metadataTask?.task.cancel()
        metadataTask = nil
        for entry in packageTasks.values { entry.task.cancel() }
        packageTasks.removeAll()
    }

    func advance() {
        guard let oid else { return }
        let now = CACurrentMediaTime()
        if metadata == nil, metadataTask == nil,
           metadataFailure?.isEligible(at: now) ?? true {
            serial &+= 1
            let request = serial
            metadataTask = (request, Task { [weak self] in
                await self?.loadMetadata(oid: oid, request: request)
            })
        }
        guard let metadata, !metadata.isClosed else { return }
        for raw in metadata.specialURLs {
            guard let url = DanmakuSpecialTransport.url(raw), packages[url] == nil,
                  packageTasks[url] == nil,
                  packageFailures[url]?.isEligible(at: now) ?? true else { continue }
            serial &+= 1
            let request = serial
            packageTasks[url] = (request, Task { [weak self] in
                await self?.loadSpecial(oid: oid, url: url, request: request)
            })
        }
    }

    @discardableResult
    func resetRetryableFailures() -> Int {
        let now = CACurrentMediaTime()
        var count = 0
        if let failure = metadataFailure, !failure.isTerminal {
            metadataFailure = failure.resetForNetworkChange(at: now)
            count += 1
        }
        for (url, failure) in packageFailures where !failure.isTerminal {
            packageFailures[url] = failure.resetForNetworkChange(at: now)
            count += 1
        }
        return count
    }

    private func acceptsMetadata(oid: Int, request: UInt64) -> Bool {
        !Task.isCancelled && self.oid == oid && metadataTask?.serial == request
    }

    private func acceptsSpecial(oid: Int, url: URL, request: UInt64) -> Bool {
        !Task.isCancelled && self.oid == oid && packageTasks[url]?.serial == request
    }

    private func loadMetadata(oid: Int, request: UInt64) async {
        defer { if metadataTask?.serial == request { metadataTask = nil } }
        let response: DanmakuSegmentResponse
        do {
            response = try await DanmakuAPI.metadata(oid: oid)
        } catch {
            guard acceptsMetadata(oid: oid, request: request),
                  !DanmakuSegmentStore.isCancellation(error) else { return }
            failMetadata(DanmakuSegmentStore.failureKind(for: error))
            return
        }
        guard acceptsMetadata(oid: oid, request: request) else { return }
        if case .failure(let kind) = DanmakuSegmentClassifier.classify(response) {
            failMetadata(kind)
            return
        }
        let decoded = await Self.decodeMetadata(response.body)
        guard acceptsMetadata(oid: oid, request: request) else { return }
        switch decoded {
        case .failure:
            failMetadata(.malformed)
        case .success(let metadata):
            self.metadata = metadata
            metadataFailure = nil
            PlayerLog.log(
                "[Danmaku] metadata state=\(metadata.state) pageSeconds=\(metadata.pageSeconds ?? 360) "
                    + "advertisedTotal=\(metadata.totalSegments ?? 0) special=\(metadata.specialURLs.count)"
            )
            onMetadata?(metadata)
            guard acceptsMetadata(oid: oid, request: request) else { return }
            advance()
        }
    }

    private func loadSpecial(oid: Int, url: URL, request: UInt64) async {
        defer { if packageTasks[url]?.serial == request { packageTasks.removeValue(forKey: url) } }
        let response: DanmakuSegmentResponse
        do {
            response = try await DanmakuSpecialTransport.fetch(url)
        } catch {
            guard acceptsSpecial(oid: oid, url: url, request: request),
                  !DanmakuSegmentStore.isCancellation(error) else { return }
            failSpecial(DanmakuSegmentStore.failureKind(for: error), url: url)
            return
        }
        guard acceptsSpecial(oid: oid, url: url, request: request) else { return }
        if case .failure(let kind) = DanmakuSegmentClassifier.classify(response) {
            failSpecial(kind, url: url)
            return
        }
        let decoded = await Self.decodeSpecial(response.body)
        guard acceptsSpecial(oid: oid, url: url, request: request) else { return }
        switch decoded {
        case .failure:
            failSpecial(.malformed, url: url)
        case .success(let index):
            packages[url] = index
            packageFailures.removeValue(forKey: url)
            if !index.isEmpty { onSpecialLoaded?() }
        }
    }

    private func failMetadata(_ kind: DanmakuSegmentFailureKind) {
        metadataFailure = .recording(kind, after: metadataFailure, at: CACurrentMediaTime())
        PlayerLog.log("[Danmaku] metadata failed class=\(kind); ordinary segments use fallback")
    }

    private func failSpecial(_ kind: DanmakuSegmentFailureKind, url: URL) {
        packageFailures[url] = .recording(kind, after: packageFailures[url], at: CACurrentMediaTime())
        PlayerLog.log("[Danmaku] special failed class=\(kind)")
    }

    private nonisolated static func decodeMetadata(
        _ data: Data
    ) async -> Result<DanmakuMetadata, DanmakuDecodeError> {
        await Task.detached(priority: .utility) {
            do throws(DanmakuDecodeError) {
                return .success(try DanmakuMetadataDecoder.decode(data))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private nonisolated static func decodeSpecial(
        _ data: Data
    ) async -> Result<DanmakuTimeIndex, DanmakuDecodeError> {
        await Task.detached(priority: .utility) {
            do throws(DanmakuDecodeError) {
                let elements = try DanmakuWireDecoder.decode(data, segmentIndex: 1)
                return .success(DanmakuTimeIndex(elements.filter { $0.renderKind != .unsupported }))
            } catch {
                return .failure(error)
            }
        }.value
    }
}
