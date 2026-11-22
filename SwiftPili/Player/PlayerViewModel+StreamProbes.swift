import Foundation
import UIKit

extension PlayerViewModel {
    nonisolated static func probeStatus(_ url: URL, timeout: TimeInterval) async -> StreamRouteProbeResult {
        await StreamRouteProbe.run(url, mode: .reachability, deadline: ContinuousClock.now + .seconds(timeout))
    }

    func probeURL(_ url: URL, evidence: StreamProbeEvidence? = nil) async -> Bool {
        guard Self.admittedNetworkURL(url, stage: "probe") != nil else { return false }
        let quietToken = beginMultiConnectionQuietWindow()
        defer { endMultiConnectionQuietWindow(quietToken) }
        guard !Task.isCancelled else { return false }
        let result = await Self.probeStatus(url, timeout: 5)
        evidence?.outcomes.append(result.outcome)
        if result.evidence == .reachable, !Task.isCancelled { return true }
        PlayerLog.log(
            "[Player] probe \(result.outcome.diagnostic) host=\(CDNHostPolicy.diagnosticHost(url.host()))"
        )
        return false
    }

}

private final class VideoProbeBodyMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let host: String
    private let maxBytes: Int
    private let start: CFTimeInterval
    private let deadline: CFTimeInterval
    private let now: @Sendable () -> CFTimeInterval
    private let access: ExperimentalAccessReceipt?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlayerViewModel.VideoHostProbe, Never>?
    private var task: URLSessionDataTask?
    private var verdict: PlayerViewModel.VideoHostProbe?
    private var bytesAccumulated = 0
    private var hit: Bool?
    private var responseMetadata: CDNProbeResponseMetadata?
    private var sawValidResponse = false
    private var responseInspected = false
    private var responseHeadersObservedAt: CFTimeInterval?
    private var firstBodyCallbackObservedAt: CFTimeInterval?

    init(
        host: String, maxBytes: Int, start: CFTimeInterval, deadline: CFTimeInterval,
        access: ExperimentalAccessReceipt? = nil,
        now: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }
    ) {
        self.host = host
        self.maxBytes = maxBytes
        self.start = start
        self.deadline = deadline
        self.now = now
        self.access = access
        super.init()
    }

    func measure(_ request: URLRequest, on session: URLSession) async -> PlayerViewModel.VideoHostProbe {
        await withCheckedContinuation { (continuation: CheckedContinuation<PlayerViewModel.VideoHostProbe, Never>) in
            lock.lock()
            if let parked = verdict {
                lock.unlock()
                continuation.resume(returning: parked)
                return
            }
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            guard access?.isValid != false else { cancel(); return }
            task.resume()
        }
    }

    func cancel() {
        var resolution: Resolution?
        lock.lock()
        if verdict == nil { resolution = resolveLocked(interruptedLocked()) }
        lock.unlock()
        resolution?.deliver()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        var resolution: Resolution?
        lock.lock()
        if verdict == nil {
            if responseHeadersObservedAt == nil { responseHeadersObservedAt = now() }
            _ = inspectResponseLocked(response)
        }
        let allow = verdict == nil && sawValidResponse
        if verdict == nil, !allow { resolution = resolveLocked(failedVerdict) }
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
        resolution?.deliver()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var resolution: Resolution?
        lock.lock()
        if verdict == nil {
            if !data.isEmpty, firstBodyCallbackObservedAt == nil { firstBodyCallbackObservedAt = now() }
            if inspectResponseLocked(dataTask.response), sawValidResponse {
                bytesAccumulated += data.count
                if bytesAccumulated >= maxBytes || now() >= deadline {
                    resolution = resolveLocked(measuredLocked())
                }
            } else {
                resolution = resolveLocked(failedVerdict)
            }
        }
        lock.unlock()
        resolution?.deliver()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var resolution: Resolution?
        lock.lock()
        if verdict == nil {
            if !inspectResponseLocked(task.response) {
                resolution = resolveLocked(failedVerdict)
            } else if error == nil, sawValidResponse {
                resolution = resolveLocked(measuredLocked())
            } else {
                resolution = resolveLocked(interruptedLocked())
            }
        }
        lock.unlock()
        resolution?.deliver()
    }

    // MARK: - Verdicts

    private func inspectResponseLocked(_ response: URLResponse?) -> Bool {
        if responseInspected { return sawValidResponse }
        guard let http = response as? HTTPURLResponse else { return true }
        responseInspected = true
        guard (200 ... 299).contains(http.statusCode) else { return false }
        for key in ["X-Cache", "X-Cache-Status", "X-Hit", "Via"] {
            guard let value = http.value(forHTTPHeaderField: key)?.lowercased() else { continue }
            if value.contains("hit") { hit = true; break }
            if value.contains("miss") { hit = false }
        }
        responseMetadata = CDNProbeResponseMetadata(response: http)
        sawValidResponse = true
        PlayerLog.log("[SmartCDN] \(host) range-support: status=\(http.statusCode) accept-ranges=\(http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-") content-length=\(http.value(forHTTPHeaderField: "Content-Length") ?? "-") content-range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "-")")
        return true
    }

    private func measuredLocked(transportTruncated: Bool = false) -> PlayerViewModel.VideoHostProbe {
        let bodyEnd = now()
        let received = min(bytesAccumulated, maxBytes)
        let bodyTime = max(bodyEnd - start, 0.005)
        let verdict = CDNProbeVerdictPolicy.verdict(
            for: CDNProbeMeasurement(
                requestedBytes: maxBytes,
                receivedBytes: received,
                endedByDeadline: received < maxBytes && bodyEnd >= deadline,
                transportTruncated: transportTruncated,
                response: responseMetadata
            )
        )
        return PlayerViewModel.VideoHostProbe(
            host: host,
            totalElapsedMs: elapsedMilliseconds(at: bodyEnd),
            rampKBps: Int(Double(received) / bodyTime / 1024),
            cacheHit: hit,
            ok: verdict != .failed,
            observedResponseHeadersMs: responseHeadersObservedAt.map(elapsedMilliseconds),
            firstObservedBodyCallbackMs: firstBodyCallbackObservedAt.map(elapsedMilliseconds),
            completedBudget: verdict == .complete,
            verdict: verdict
        )
    }

    private func interruptedLocked() -> PlayerViewModel.VideoHostProbe {
        guard sawValidResponse else { return failedVerdict }
        return measuredLocked(transportTruncated: true)
    }

    private var failedVerdict: PlayerViewModel.VideoHostProbe {
        PlayerViewModel.VideoHostProbe(
            host: host, totalElapsedMs: elapsedMilliseconds(at: now()), rampKBps: 0, cacheHit: nil, ok: false,
            observedResponseHeadersMs: responseHeadersObservedAt.map(elapsedMilliseconds),
            firstObservedBodyCallbackMs: firstBodyCallbackObservedAt.map(elapsedMilliseconds)
        )
    }

    private func elapsedMilliseconds(at time: CFTimeInterval) -> Int {
        Int(max(time - start, 0) * 1000)
    }

    // MARK: - Resolve once

    private struct Resolution {
        let continuation: CheckedContinuation<PlayerViewModel.VideoHostProbe, Never>?
        let task: URLSessionDataTask?
        let probe: PlayerViewModel.VideoHostProbe

        func deliver() {
            task?.cancel()
            continuation?.resume(returning: probe)
        }
    }

    private func resolveLocked(_ probe: PlayerViewModel.VideoHostProbe) -> Resolution? {
        guard verdict == nil else { return nil }
        verdict = probe
        let resolution = Resolution(continuation: continuation, task: task, probe: probe)
        continuation = nil
        task = nil
        return resolution
    }
}

extension PlayerViewModel {
    static let probeStartupDeferralCap: TimeInterval = 8

    // MARK: - Smart CDN per-video cache probe (phase 2)

    struct VideoHostProbe: Sendable {
        let host: String
        let totalElapsedMs: Int
        let observedResponseHeadersMs: Int?
        let firstObservedBodyCallbackMs: Int?
        let rampKBps: Int
        let cacheHit: Bool?
        let ok: Bool
        let verdict: CDNProbeVerdict
        var completedBudget: Bool = true

        init(
            host: String,
            totalElapsedMs: Int,
            rampKBps: Int,
            cacheHit: Bool?,
            ok: Bool,
            observedResponseHeadersMs: Int? = nil,
            firstObservedBodyCallbackMs: Int? = nil,
            completedBudget: Bool = true,
            verdict: CDNProbeVerdict? = nil
        ) {
            self.host = host
            self.totalElapsedMs = totalElapsedMs
            self.observedResponseHeadersMs = observedResponseHeadersMs
            self.firstObservedBodyCallbackMs = firstObservedBodyCallbackMs
            self.rampKBps = rampKBps
            self.cacheHit = cacheHit
            self.ok = ok
            self.completedBudget = completedBudget
            self.verdict = verdict ?? (ok && completedBudget ? .complete : (ok ? .partial : .failed))
        }

        var isHealthyForFailover: Bool {
            CDNProbeVerdictPolicy.isHealthy(verdict)
        }

        var isEligibleForRamp: Bool {
            isHealthyForFailover && ok && completedBudget
        }
    }

    func probeVideoAcrossHosts(videoURL: URL, generation: Int) {
        guard let admittedVideo = Self.admittedNetworkURL(videoURL, stage: "delivery-probe") else {
            return
        }
        let currentHost = CDNHostPolicy.canonicalHost(admittedVideo.host()) ?? ""
        let armKey = "\(generation)|\(currentHost)"
        guard armKey != lastArmedProbeKey else { return }
        var candidates = [admittedVideo]
        for service in SmartCDNSelector.shared.failoverServices(excluding: currentHost).prefix(2) {
            guard let rewritten = service.safeRewriteURL(admittedVideo),
                  let admitted = Self.admittedNetworkURL(rewritten, stage: "delivery-rewrite")
            else { continue }
            if CDNHostPolicy.canonicalHost(admitted.host()) != currentHost {
                candidates.append(admitted)
            }
        }
        guard candidates.count > 1 else { return }
        lastArmedProbeKey = armKey
        videoProbeTask?.cancel()
        videoHostProbes = [:]
        let minBytes = 512 * 1024
        let expensive = SmartCDNSelector.shared.pathIsExpensive
        let useMinimal = expensive && !SmartCDNSelector.scaleProbeOnCellular
        let bitrate = streamNominalBitrate > 0 ? streamNominalBitrate : stats.bitrate
        let wantedBytes = bitrate > 0 ? bitrate / 8 * 2 : minBytes
        let budgetBytes = Int(SmartCDNSelector.probeBudgetMB * 1024 * 1024)
        let maxBytes = useMinimal ? minBytes : min(max(wantedBytes, minBytes), budgetBytes)
        let maxSeconds = useMinimal ? 0.6 : 2.0
        let experimentalAccess = ExperimentalSettingsStore.shared.captureAccess(.http2Probe)
        let http2 = experimentalAccess != nil
        videoProbeExperimentalAccess = experimentalAccess
        PlayerLog.log("[SmartCDN] probe budget: \(maxBytes / 1024)KB/host ≤\(String(format: "%.1f", maxSeconds))s (bitrate=\(bitrate / 1000)kbps expensive=\(expensive) http2=\(http2))")
        videoProbeTask = Task { [weak self] in
            guard let owner = self else { return }
            await owner.awaitPresentationStart(timeout: Self.probeStartupDeferralCap)
            guard !Task.isCancelled, owner.loadGeneration == generation,
                  experimentalAccess.map(ExperimentalSettingsStore.shared.isCurrentAccess) ?? true
            else { return }
            let quietToken = owner.beginMultiConnectionQuietWindow()
            defer { owner.endMultiConnectionQuietWindow(quietToken) }
            let probes = await withTaskGroup(of: VideoHostProbe?.self) { group in
                for url in candidates {
                    group.addTask { () -> VideoHostProbe? in
                        guard !Task.isCancelled, experimentalAccess?.isValid != false else { return nil }
                        let probe = await Self.probeVideoURL(
                            url, maxBytes: maxBytes, maxSeconds: maxSeconds, http2: http2, access: experimentalAccess
                        )
                        guard !Task.isCancelled, experimentalAccess?.isValid != false else { return nil }
                        return probe
                    }
                }
                var out: [VideoHostProbe] = []
                for await probe in group { if let probe { out.append(probe) } }
                return out
            }
            guard let self, !Task.isCancelled, self.loadGeneration == generation,
                  experimentalAccess.map(ExperimentalSettingsStore.shared.isCurrentAccess) ?? true
            else { return }
            for probe in probes { self.videoHostProbes[probe.host] = probe }
            for probe in probes where probe.isEligibleForRamp && probe.rampKBps > 0 && probe.cacheHit == true &&
                CDNHostPolicy.allowsHost(probe.host) {
                SmartCDNSelector.shared.recordRamp(
                    host: probe.host,
                    kBps: probe.rampKBps,
                    verdict: probe.verdict
                )
            }
            let summary = probes.map {
                "\($0.host.split(separator: ".").first.map(String.init) ?? $0.host)=" +
                    ($0.ok
                        ? "total=\($0.totalElapsedMs)ms/" +
                            "headersObserved=\($0.observedResponseHeadersMs.map(String.init) ?? "—")ms/" +
                            "bodyCallbackObserved=\($0.firstObservedBodyCallbackMs.map(String.init) ?? "—")ms/" +
                            "\($0.cacheHit.map { $0 ? "HIT" : "MISS" } ?? "—")/" +
                            "\(String(format: "%.1f", Double($0.rampKBps) / 1024))MB/s"
                        : "FAIL") +
                    ($0.verdict == .partial ? "/PARTIAL" : "")
            }.joined(separator: "  ")
            let best = probes.filter(\.isHealthyForFailover).max(by: { $0.rampKBps < $1.rampKBps })
            let currentHost = self.stats.videoHost.split(separator: ".").first.map(String.init) ?? self.stats.videoHost
            PlayerLog.log("[SmartCDN] video probe (\(maxBytes / 1024)KB): \(summary)  playing=\(currentHost)\(best.map { " fastest=\($0.host.split(separator: ".").first ?? Substring($0.host))" } ?? "")")
        }
    }

    private nonisolated static func probeVideoURL(
        _ url: URL, maxBytes: Int, maxSeconds: Double, http2: Bool, access: ExperimentalAccessReceipt?
    ) async -> VideoHostProbe {
        let host = CDNHostPolicy.canonicalHost(url.host()) ?? "?"
        guard CDNHostPolicy.allows(url) else {
            return VideoHostProbe(
                host: CDNHostPolicy.diagnosticHost(host), totalElapsedMs: 0, rampKBps: 0, cacheHit: nil, ok: false
            )
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("bytes=0-\(max(maxBytes - 1, 0))", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        if http2 { request.assumesHTTP3Capable = true }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        let start = CACurrentMediaTime()
        let deadline = start + maxSeconds
        let meter = VideoProbeBodyMeter(
            host: host, maxBytes: maxBytes, start: start, deadline: deadline, access: access
        )
        let session = URLSession(configuration: config, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let wall = Task {
            try? await Task.sleep(for: .seconds(maxSeconds + 0.25))
            session.invalidateAndCancel()
        }
        defer { wall.cancel() }
        return await withTaskCancellationHandler {
            await meter.measure(request, on: session)
        } onCancel: {
            meter.cancel()
        }
    }
}
