import Foundation

struct DemandDASHRouteResume: Sendable {
    static let minimumPosition: TimeInterval = 0.5

    let startAt: TimeInterval
    let track: MediaTrackKind
    let failedHost: String?
}

extension PlayerViewModel {
    private static let resumeProbeFanout = 6

    func pickResumeURL(
        _ urls: [String], resume: DemandDASHRouteResume, evidence: StreamProbeEvidence,
        requestAdmission: @escaping @MainActor @Sendable () -> Bool
    ) async -> URL? {
        let admits: StreamRouteProbe.Admission = { [weak self] url in
            !Task.isCancelled && requestAdmission() && self?.admitsResumeCandidate(url, resume: resume) == true
        }
        let candidates = resumeCandidates(urls, resume: resume)
        guard !candidates.preference.isEmpty, requestAdmission(), !Task.isCancelled else { return nil }
        let quietToken = beginMultiConnectionQuietWindow()
        defer { endMultiConnectionQuietWindow(quietToken) }

        let shortlist = candidates.preference.prefix(Self.resumeProbeFanout)
        let preferenceEvidence = StreamProbeEvidence()
        if let winner = await probeResumeCandidates(
            shortlist, mode: .resume, evidence: preferenceEvidence, admits: admits
        ) {
            guard admits(winner.url) else { return nil }
            evidence.outcomes.append(contentsOf: preferenceEvidence.outcomes)
            let result = winner.evidence == .partial ? "partial" : "compatible-200"
            logResumeSelection(winner.url, track: resume.track, result: result)
            return winner.url
        }

        let reachableCandidates = candidates.compatibility
        for start in stride(from: 0, to: reachableCandidates.count, by: Self.resumeProbeFanout) {
            guard !Task.isCancelled, requestAdmission() else { return nil }
            let end = min(start + Self.resumeProbeFanout, reachableCandidates.count)
            let batch = reachableCandidates[start..<end]
            if let winner = await probeResumeCandidates(
                batch, mode: .reachability, evidence: evidence, admits: admits
            ) {
                guard admits(winner.url) else { return nil }
                logResumeSelection(winner.url, track: resume.track, result: "compatible-headers")
                return winner.url
            }
        }
        return nil
    }

    private func logResumeSelection(_ url: URL, track: MediaTrackKind, result: String) {
        let host = CDNHostPolicy.diagnosticHost(url.host())
        PlayerLog.log("[CDN] DASH resume track=\(track.rawValue) host=\(host) evidence=\(result)")
    }

    private struct CandidatePlan {
        let preference: [URL]
        let compatibility: [URL]
    }

    private func resumeCandidates(_ urls: [String], resume: DemandDASHRouteResume) -> CandidatePlan {
        let api = urls.compactMap { URL(string: $0) }
        guard let base = api.first else { return CandidatePlan(preference: [], compatibility: []) }
        let smart = SmartCDNSelector.isEnabled
        let selector = SmartCDNSelector.shared
        let ranked = smart ? selector.failoverServices(excluding: resume.failedHost) : []
        let services = Self.rankFallbackServicesByProbe(ranked, probes: videoHostProbes)
        let apiStrings = Set(api.map(\.absoluteString))

        func actualURL(for candidate: URL) -> URL {
            if apiStrings.contains(candidate.absoluteString) { return candidate }
            let host = CDNHostPolicy.canonicalHost(candidate.host())
            return api.first { CDNHostPolicy.canonicalHost($0.host()) == host } ?? candidate
        }
        func admit(_ urls: [URL]) -> [URL] {
            var seen = Set<String>()
            return urls.filter {
                admitsResumeCandidate($0, resume: resume) && seen.insert($0.absoluteString).inserted
            }
        }
        let preferred = applyCDN(urls).map { [$0] } ?? []
        let rankedURLs = services.compactMap { $0.safeRewriteURL(base) }
        let bootstrapMirrors = smart && selector.hasRanking ? [] : Self.fallbackMirrors.compactMap {
            $0.safeRewriteURL(base)
        }
        let rankedHead = Array(admit((preferred + rankedURLs).map { actualURL(for: $0) }).prefix(4))
        return CandidatePlan(
            preference: admit(rankedHead + api + bootstrapMirrors),
            compatibility: admit(preferred + Array(admit(rankedURLs).prefix(4)) + api + bootstrapMirrors)
        )
    }

    private func admitsResumeCandidate(_ url: URL, resume: DemandDASHRouteResume) -> Bool {
        guard CDNHostPolicy.allows(url), CDNHostPolicy.admitsVODHost(url),
              let host = CDNHostPolicy.canonicalHost(url.host()), host != resume.failedHost,
              isVideoHostHealthyOrUnknown(host) else { return false }
        return !SmartCDNSelector.isEnabled || !SmartCDNSelector.shared.excludesPrefetchHost(host)
    }

    private func probeResumeCandidates(
        _ candidates: ArraySlice<URL>, mode: StreamRouteProbe.Mode, evidence: StreamProbeEvidence,
        admits: @escaping StreamRouteProbe.Admission
    ) async -> (url: URL, evidence: StreamRouteProbeResult.Evidence)? {
        let deadline = ContinuousClock.now + .seconds(mode == .resume ? 2 : 5)
        let preferredEvidence: StreamRouteProbeResult.Evidence = mode == .resume ? .partial : .reachable
        typealias Winner = (url: URL, evidence: StreamRouteProbeResult.Evidence)
        return await withTaskGroup(of: (Int, StreamRouteProbeResult).self, returning: Winner?.self) { group in
            for index in candidates.indices {
                let url = candidates[index]
                group.addTask {
                    let result = await StreamRouteProbe.run(url, mode: mode, deadline: deadline, admits: admits)
                    return (index, result)
                }
            }
            var finished: [Int: StreamRouteProbeResult.Evidence] = [:]
            for await (index, result) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return nil
                }
                evidence.outcomes.append(result.outcome)
                finished[index] = result.evidence
                for offset in candidates.indices {
                    guard let verdict = finished[offset] else { break }
                    let candidate = candidates[offset]
                    if verdict == preferredEvidence, admits(candidate) {
                        group.cancelAll()
                        return (candidate, verdict)
                    }
                }
            }
            return candidates.indices.first {
                finished[$0] == .reachable && admits(candidates[$0])
            }.map { (candidates[$0], .reachable) }
        }
    }
}
