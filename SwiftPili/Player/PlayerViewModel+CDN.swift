import Foundation
import UIKit

extension PlayerViewModel {

    /// The shared network-source admission boundary. Callers retain the
    /// original URL object (and therefore its signed path/query bytes); this
    /// helper only decides whether it may cross a network side-effect.
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

    /// String form of the same admission boundary. Returning the original
    /// string is intentional: URLComponents/URL reconstruction can alter
    /// signed percent-encoded query bytes.
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

    /// Picks the preferred CDN URL, but verifies it is actually reachable —
    /// when it isn't (invalid TLS cert, unreachable host…), every candidate
    /// host is latency-raced and the fastest responder wins.
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
        // VOD CDN trust (Settings → Block PCDN). With the setting off every
        // admitted host is trusted, so this whole block is a no-op.
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
                // Every URL is PCDN — offer the standard mirrors instead
                // and let the latency race pick among them.
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
        // After a playback failure (cdnFallbackActive) skip straight to the latency race — that host already
        // let us down once.  …unless the sweep already proved this host in THIS session, in which case the
        // probe is a round trip the first frame waits for and learns nothing from.
        if !cdnFallbackActive,
           let host = preferred.host(),
           SmartCDNSelector.shared.hasSessionReachabilityEvidence(for: host) {
            // No StartupTrace mark of its own: the `cdn-probe-started` →
            // `cdn-selected` bracket already surrounds this decision, and a skip
            // shows up there as a ~0ms stage. This line names the reason.
            PlayerLog.log(
                "[CDN] pre-open probe skipped — host=\(CDNHostPolicy.diagnosticHost(host)) " +
                    "already answered this session (sweep/ramp)"
            )
            return preferred
        }
        if !cdnFallbackActive, await probeURL(preferred, evidence: evidence) { return preferred }

        // On a fallback reload, bar the host that just failed mid-stream — it can still win a 1-byte probe
        // while being unable to sustain playback (stats.videoHost is updated only when the new stream starts,
        // so here it still names the failed one).
        let excluded = cdnFallbackActive ? stats.videoHost : nil

        // Smart mode: the failed node goes to the temporary blacklist and
        // the failover walks the selector's ranking (same ISP > same
        // province > latency) instead of a blind latency race.
        if SmartCDNSelector.isEnabled {
            if let excluded, !excluded.isEmpty {
                SmartCDNSelector.shared.reportPlaybackIssue(
                    host: excluded, reason: "playback failure/stutter fallback"
                )
            }
            // No mid-play failure (plain startup probe miss): still skip the host that just failed the probe —
            // re-probing it first would burn another timeout.
            let smartExcluded = (excluded?.isEmpty == false) ? excluded : preferred.host()
            if let smart = await smartRankedFallbackURL(from: urls, excluding: smartExcluded, evidence: evidence) {
                return smart
            }
            // Smart mode owns its failover end-to-end — the standard mirror race would override the sweep's
            // knowledge with a 1-byte RTT verdict, the exact signal Smart CDN exists to beat.
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

    /// Requirement: failover is never random — it follows same ISP > same province > latency order.
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
        // Per-video cache knowledge (phase 2 probes): an edge that already HOLDS this video beats abstract
        // rank order — a MISS edge would pull it from origin, the exact slowness we're failing away from.
        let probes = videoHostProbes
        if !probes.isEmpty {
            services = Self.rankFallbackServicesByProbe(services, probes: probes)
        }
        // Bounded: probing the whole ranking would delay recovery.
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

    /// A tiny reachability success cannot override this stream's recorded
    /// partial/failed delivery measurement. Unmeasured hosts remain candidates.
    func isVideoHostHealthyOrUnknown(_ host: String?) -> Bool {
        guard let key = CDNHostPolicy.canonicalHost(host), let probe = videoHostProbes[key] else { return true }
        return probe.isHealthyForFailover
    }

    /// Mirrors added to the latency race besides the API-returned hosts.
    static let fallbackMirrors: [CDNService] = [.ali, .cos, .hw]

    /// Races every candidate host (raw API URLs + domestic mirror rewrites) with concurrent 1-byte probes and
    /// returns the first successful responder — by construction the lowest-latency responsive node.
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
            // Unless it's the only option left.
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

        // Before the first sweep finishes (or with everything blacklisted) it returns nil and the manual
        // choice below still applies.
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

        // (Fallback after a failure is handled by the latency race in
        // pickReachableURL, not by forcing a fixed mirror here.)

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
