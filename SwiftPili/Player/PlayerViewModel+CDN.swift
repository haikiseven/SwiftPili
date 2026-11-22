import Foundation
import UIKit

extension PlayerViewModel {

    static func admittedNetworkURL(_ url: URL, stage: String) -> URL? {
        let decision = CDNHostPolicy.decision(for: url)
        guard decision.isAllowed else {
            PlayerLog.log(
                "[CDN] rejected stage=\(stage) host=\(CDNHostPolicy.diagnosticHost(url.host())) " +
                    "reason=\(decision.reason)"
            )
            return nil
        }
        return url
    }

    static func admittedNetworkURLString(_ rawURL: String, stage: String) -> String? {
        guard let url = URL(string: rawURL) else {
            PlayerLog.log("[CDN] rejected stage=\(stage) host=invalid reason=malformed_url")
            return nil
        }
        guard admittedNetworkURL(url, stage: stage) != nil else { return nil }
        return rawURL
    }

    static func diagnosticURL(_ url: URL) -> String {
        let host = CDNHostPolicy.diagnosticHost(url.host())
        let path = String(url.path.prefix(96))
        return path.isEmpty ? host : "\(host)\(path)"
    }

    static func urlStillFresh(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard CDNHostPolicy.allows(url) else { return false }
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "deadline" })?.value,
            let deadline = TimeInterval(raw)
        else { return true }
        return Date().timeIntervalSince1970 < deadline - 30
    }

    // MARK: - Reachability probes & URL selection

    func pickReachableURL(_ rawURLs: [String]) async -> URL? {
        await selectReachableURL(rawURLs).url
    }

    func selectReachableURL(
        _ rawURLs: [String], resume: DemandDASHRouteResume? = nil,
        requestAdmission: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> StreamURLSelection {
        let evidence = StreamProbeEvidence()
        let url = await pickReachableURL(
            rawURLs, evidence: evidence, resume: resume, requestAdmission: requestAdmission
        )
        let cancelled = Task.isCancelled || !requestAdmission()
        return StreamURLSelection(url: cancelled ? nil : url, outcomes: evidence.outcomes, cancelled: cancelled)
    }

    private func pickReachableURL(
        _ rawURLs: [String], evidence: StreamProbeEvidence, resume: DemandDASHRouteResume?,
        requestAdmission: @escaping @MainActor @Sendable () -> Bool
    ) async -> URL? {
        guard !Task.isCancelled, requestAdmission(),
              let urls = admittedVODCandidates(rawURLs, evidence: evidence) else { return nil }
        if let resume, resume.startAt > DemandDASHRouteResume.minimumPosition {
            return await pickResumeURL(urls, resume: resume, evidence: evidence, requestAdmission: requestAdmission)
        }
        return await pickLegacyReachableURL(urls, evidence: evidence)
    }

    private func admittedVODCandidates(_ rawURLs: [String], evidence: StreamProbeEvidence) -> [String]? {
        var urls = rawURLs.compactMap { raw -> String? in
            guard let admitted = Self.admittedNetworkURLString(raw, stage: "candidate") else {
                evidence.outcomes.append(.init(host: nil, status: nil, failure: nil, rejection: .structural))
                return nil
            }
            return admitted
        }
        guard !urls.isEmpty else {
            PlayerLog.log("[CDN] no admitted candidates stage=candidate")
            return nil
        }
        let trusted = urls.filter { raw in
            let url = URL(string: raw)
            let trusted = url.map(CDNHostPolicy.admitsVODHost) ?? false
            if !trusted {
                evidence.outcomes.append(.init(host: CDNHostPolicy.canonicalHost(url?.host()),
                    status: nil, failure: nil, rejection: .trustPolicy))
            }
            return trusted
        }
        if trusted.count < urls.count {
            if trusted.isEmpty, let first = urls.compactMap({ URL(string: $0) }).first {
                PlayerLog.log("[Player] all \(urls.count) URLs are PCDN — racing standard mirrors")
                urls = Self.fallbackMirrors.compactMap {
                    $0.safeRewriteURL(first)?.absoluteString
                }
            } else {
                PlayerLog.log("[Player] dropped \(urls.count - trusted.count) PCDN candidate(s)")
                urls = trusted
            }
        }

        return urls
    }

    private func pickLegacyReachableURL(_ urls: [String], evidence: StreamProbeEvidence) async -> URL? {
        guard let preferred = applyCDN(urls) else { return nil }
        guard let preferred = Self.admittedNetworkURL(preferred, stage: "preferred") else {
            return nil
        }
        if !cdnFallbackActive,
           let host = preferred.host(),
           SmartCDNSelector.shared.hasSessionReachabilityEvidence(for: host) {
            PlayerLog.log(
                "[CDN] pre-open probe skipped — host=\(CDNHostPolicy.diagnosticHost(host)) " +
                    "already answered this session (sweep/ramp)"
            )
            return preferred
        }
        if !cdnFallbackActive, await probeURL(preferred, evidence: evidence) { return preferred }

        let excluded = cdnFallbackActive ? stats.videoHost : nil

        if SmartCDNSelector.isEnabled {
            if let excluded, !excluded.isEmpty {
                SmartCDNSelector.shared.reportPlaybackIssue(
                    host: excluded, reason: "playback failure/stutter fallback"
                )
            }
            let smartExcluded = (excluded?.isEmpty == false) ? excluded : preferred.host()
            if let smart = await smartRankedFallbackURL(from: urls, excluding: smartExcluded, evidence: evidence) {
                return smart
            }
            if SmartCDNSelector.shared.hasRanking {
                for candidate in urls.compactMap({ URL(string: $0) }) where
                    CDNHostPolicy.canonicalHost(candidate.host()) != CDNHostPolicy.canonicalHost(smartExcluded) {
                    guard let candidate = Self.admittedNetworkURL(candidate, stage: "ranked-failover"),
                          isVideoHostHealthyOrUnknown(candidate.host()) else {
                        continue
                    }
                    if await probeURL(candidate, evidence: evidence), isVideoHostHealthyOrUnknown(candidate.host()) {
                        PlayerLog.log("[SmartCDN] ranking exhausted — using API-provided host=\(CDNHostPolicy.diagnosticHost(candidate.host()))")
                        return candidate
                    }
                }
                PlayerLog.log("[SmartCDN] ranking and API hosts exhausted — no candidate")
                return nil
            }
            PlayerLog.log("[SmartCDN] no sweep ranking yet — latency race as bootstrap")
        }

        if let best = await lowestLatencyURL(from: urls, excluding: excluded, evidence: evidence) {
            if best.host() != preferred.host() {
                PlayerLog.log("[Player] CDN fallback: \(preferred.host() ?? "") → \(best.host() ?? "")")
            }
            return best
        }
        PlayerLog.log("[Player] no candidate URL probed OK — no reachable stream")
        return nil
    }

    func smartRankedFallbackURL(
        from urls: [String], excluding excludedHost: String?,
        rankedServices: [CDNService]? = nil,
        evidence: StreamProbeEvidence? = nil
    ) async -> URL? {
        guard let base = urls.compactMap({ URL(string: $0) }).compactMap({
            Self.admittedNetworkURL($0, stage: "ranked-base")
        }).first else { return nil }
        let excludedKey = CDNHostPolicy.canonicalHost(excludedHost)
        var services = (rankedServices ?? SmartCDNSelector.shared.failoverServices(excluding: excludedHost))
            .filter { isVideoHostHealthyOrUnknown($0.host) }
        guard !services.isEmpty else { return nil }
        let probes = videoHostProbes
        if !probes.isEmpty {
            services = Self.rankFallbackServicesByProbe(services, probes: probes)
        }
        for service in services.prefix(4) {
            guard let candidate = service.safeRewriteURL(base),
                  let admitted = Self.admittedNetworkURL(candidate, stage: "ranked-rewrite"),
                  CDNHostPolicy.canonicalHost(admitted.host()) != excludedKey,
                  isVideoHostHealthyOrUnknown(admitted.host())
            else { continue }
            if await probeURL(admitted, evidence: evidence),
               isVideoHostHealthyOrUnknown(admitted.host()) {
                PlayerLog.log("[Player] smart failover: \(CDNHostPolicy.diagnosticHost(excludedHost)) → \(CDNHostPolicy.diagnosticHost(admitted.host()) ) (rank order)")
                return admitted
            }
            PlayerLog.log("[Player] smart failover host=\(CDNHostPolicy.diagnosticHost(admitted.host())) probe failed — trying next in rank")
        }
        return nil
    }

    static func rankFallbackServicesByProbe(
        _ services: [CDNService],
        probes: [String: VideoHostProbe]
    ) -> [CDNService] {
        let maxRamp = services.compactMap { service -> Int? in
            guard let host = service.host, let kbps = probes[host]?.rampKBps, kbps > 0 else { return nil }
            return kbps
        }.max() ?? 0
        return services.enumerated().sorted { lhs, rhs in
            let lhsScore = fallbackProbeScore(lhs.element, probes: probes)
            let rhsScore = fallbackProbeScore(rhs.element, probes: probes)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsTier = fallbackRampTier(lhs.element, probes: probes, maxRamp: maxRamp)
            let rhsTier = fallbackRampTier(rhs.element, probes: probes, maxRamp: maxRamp)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            let lhsRamp = lhs.element.host.flatMap { probes[$0]?.rampKBps } ?? 0
            let rhsRamp = rhs.element.host.flatMap { probes[$0]?.rampKBps } ?? 0
            if lhsRamp > 0, rhsRamp > 0 {
                if lhsRamp * 2 > rhsRamp * 3 { return true }
                if rhsRamp * 2 > lhsRamp * 3 { return false }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func fallbackProbeScore(
        _ service: CDNService,
        probes: [String: VideoHostProbe]
    ) -> Int {
        guard let host = service.host, let probe = probes[host] else { return 2 }
        if probe.cacheHit == true { return 4 }
        return probe.cacheHit == nil ? 3 : 1
    }

    private static func fallbackRampTier(
        _ service: CDNService,
        probes: [String: VideoHostProbe],
        maxRamp: Int
    ) -> Int {
        guard maxRamp > 0, let host = service.host,
              let kbps = probes[host]?.rampKBps, kbps > 0 else { return 1 }
        if kbps * 3 >= maxRamp * 2 { return 0 }
        return kbps * 2 >= maxRamp ? 1 : 2
    }

    func isVideoHostHealthyOrUnknown(_ host: String?) -> Bool {
        guard let key = CDNHostPolicy.canonicalHost(host), let probe = videoHostProbes[key] else { return true }
        return probe.isHealthyForFailover
    }

    static let fallbackMirrors: [CDNService] = [.ali, .cos, .hw]

    func lowestLatencyURL(
        from urls: [String], excluding excludedHost: String? = nil, evidence: StreamProbeEvidence? = nil
    ) async -> URL? {
        let quietToken = beginMultiConnectionQuietWindow()
        defer { endMultiConnectionQuietWindow(quietToken) }
        var candidates = urls.compactMap { URL(string: $0) }.compactMap {
            Self.admittedNetworkURL($0, stage: "race-candidate")
        }
        if let base = candidates.first {
            for mirror in Self.fallbackMirrors {
                if let rewritten = mirror.safeRewriteURL(base),
                   let admitted = Self.admittedNetworkURL(rewritten, stage: "race-rewrite") {
                    candidates.append(admitted)
                }
            }
        }
        var seenHosts = Set<String>()
        candidates = candidates.filter {
            guard let host = CDNHostPolicy.canonicalHost($0.host()) else { return false }
            return seenHosts.insert(host).inserted
        }
        let excludedKey = CDNHostPolicy.canonicalHost(excludedHost)
        if let excludedKey {
            let filtered = candidates.filter { CDNHostPolicy.canonicalHost($0.host()) != excludedKey }
            if !filtered.isEmpty { candidates = filtered }
        }
        guard !candidates.isEmpty else { return nil }

        let raceStart = CACurrentMediaTime()
        let winner = await withTaskGroup(
            of: (URL, TimeInterval, StreamProbeOutcome, Bool).self, returning: URL?.self
        ) { group in
            for url in candidates {
                group.addTask {
                    let start = CACurrentMediaTime()
                    let result = await Self.probeStatus(url, timeout: 4)
                    let succeeded = result.evidence == .reachable && !Task.isCancelled
                    return (url, CACurrentMediaTime() - start, result.outcome, succeeded)
                }
            }
            for await (url, latency, outcome, succeeded) in group {
                evidence?.outcomes.append(outcome)
                if succeeded, !Task.isCancelled {
                    group.cancelAll()
                    PlayerLog.log("[Player] CDN race (\(candidates.count) hosts): \(url.host() ?? "") won in \(Int(latency * 1000))ms")
                    return url
                }
            }
            return nil
        }
        if winner == nil {
            PlayerLog.log("[Player] CDN race: all \(candidates.count) hosts failed in \(String(format: "%.1f", CACurrentMediaTime() - raceStart))s")
        }
        return winner
    }

    func applyCDN(_ urls: [String]) -> URL? {
        let cdn = CDNService.current
        let parsed = urls.compactMap { URL(string: $0) }

        if SmartCDNSelector.isEnabled {
            if let node = SmartCDNSelector.shared.nodeForPlayback(), let base = parsed.first {
                guard let url = node.service.safeRewriteURL(base),
                      let admitted = Self.admittedNetworkURL(url, stage: "smart-rewrite")
                else { return nil }
                if lastCDNLogGeneration != loadGeneration {
                    lastCDNLogGeneration = loadGeneration
                    let selector = SmartCDNSelector.shared
                    let rampInfo = selector.measuredRamp(for: node.host)
                        .map { String(format: " ramp=%.1fMB/s", Double($0) / 1024) } ?? ""
                    let ranked = selector.rankedHosts(limit: 5).enumerated().map { (i, h) in
                        let marker = h == node.host ? "▶" : " "
                        let ewma = selector.measuredRamp(for: h).map { String(format: "%.1fMB/s", Double($0) / 1024) } ?? "—"
                        return "\(marker)\(i + 1).\(h.split(separator: ".").first ?? Substring(h))(\(ewma))"
                    }.joined(separator: " ")
                    PlayerLog.log("[SmartCDN] ▶ stream: \(node.host) bucket=\(node.bucket) lat=\(node.latencyMs)ms\(rampInfo) | ranking: \(ranked)")
                }
                return admitted
            }
            PlayerLog.log("[Player] smart CDN enabled but no ranked node yet — using manual setting (\(cdn.rawValue))")
        }

        switch cdn {
        case .baseUrl:
            return parsed.first.flatMap { Self.admittedNetworkURL($0, stage: "manual-base") }
        case .backupUrl:
            if let standard = parsed.first(where: { $0.port == nil || $0.port == 443 }) {
                return Self.admittedNetworkURL(standard, stage: "manual-backup")
            }
            return parsed.dropFirst(1).first.flatMap {
                Self.admittedNetworkURL($0, stage: "manual-backup")
            } ?? parsed.first.flatMap {
                Self.admittedNetworkURL($0, stage: "manual-backup")
            }
        default:
            if let base = parsed.first {
                return cdn.safeRewriteURL(base).flatMap {
                    Self.admittedNetworkURL($0, stage: "manual-rewrite")
                }
            }
            return nil
        }
    }
}
