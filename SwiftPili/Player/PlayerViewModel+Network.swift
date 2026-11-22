import AVFoundation
import Foundation
import Network
import UIKit

extension PlayerViewModel {

    nonisolated static func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { path in
            let classChanged = multiConnectionPath.withLock { current -> Bool in
                let previous = current.networkClass
                current = MultiConnectionNetworkPath(
                    satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi),
                    cellular: path.usesInterfaceType(.cellular),
                    expensive: path.isExpensive,
                    constrained: path.isConstrained
                )
                return current.networkClass != previous
            }
            // Ladder levels and hard rests were learned on another network.
            if classChanged { MultiConnectionLadderMemo.shared.reset() }
            Task { @MainActor in PlayerViewModel.shared.refreshMultiConnectionQuiet() }
            if path.usesInterfaceType(.wifi) {
                currentNetwork = .wifi
            } else {
                currentNetwork = .cellular
            }
            noteDanmakuPathUpdate(path)
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// Only a change INTO a satisfied path reopens failures: retrying onto a route that cannot carry traffic
    /// would only spend attempts.
    private nonisolated static func noteDanmakuPathUpdate(_ path: NWPath) {
        var active: [String] = []
        if path.usesInterfaceType(.wifi) { active.append("wifi") }
        if path.usesInterfaceType(.cellular) { active.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { active.append("wired") }
        if path.usesInterfaceType(.other) { active.append("other") }
        let satisfied = path.status == .satisfied
        let signature = (active.isEmpty ? "none" : active.joined(separator: "+"))
            + (satisfied ? "" : "|unsatisfied")
        let previous = danmakuLastPathSignature.withLock { last -> String? in
            defer { last = signature }
            return last
        }
        guard let previous, previous != signature, satisfied else { return }
        Task { @MainActor in
            PlayerViewModel.shared.noteDanmakuNetworkPathChanged(from: previous, to: signature)
        }
    }
}

struct MultiConnectionNetworkPath: Equatable, Sendable {
    var satisfied = false
    var wifi = false
    var cellular = false
    var expensive = false
    var constrained = false

    /// Low Data Mode and an unsatisfied path never prefetch. Anything iOS marks
    /// expensive — cellular, and a personal hotspot on a Wi-Fi interface — is `.expensive`.
    var networkClass: MultiConnectionNetworkClass {
        guard satisfied, !constrained else { return .unavailable }
        return wifi && !cellular && !expensive ? .wifi : .expensive
    }

    func admits(cellularEnabled: Bool) -> Bool {
        switch networkClass {
        case .wifi: true
        case .expensive: cellularEnabled
        case .unavailable: false
        }
    }
}

/// Tokens prevent a cancelled older probe from releasing a successor's quiet window.
struct MultiConnectionQuietWindows {
    private var probes: Set<UUID> = []
    var sweepActive = false
    var isQuiet: Bool { sweepActive || !probes.isEmpty }

    mutating func beginProbe() -> UUID {
        let token = UUID()
        probes.insert(token)
        return token
    }

    mutating func endProbe(_ token: UUID) {
        probes.remove(token)
    }
}

enum MultiConnectionVODCandidates {
    /// One policy per open: a prefetcher opened on Wi-Fi has a session that forbids expensive interfaces, so it
    /// stays quiet there until Wi-Fi returns or the next load, toggle or not.
    static func prefetchQuiet(
        enabled: Bool, path: MultiConnectionNetworkPath, cellularEnabled: Bool,
        loadClass: MultiConnectionNetworkClass?, measuring: Bool
    ) -> MultiConnectionQuiet {
        if !enabled || !path.admits(cellularEnabled: cellularEnabled)
            || (loadClass == .wifi && path.networkClass == .expensive) {
            return .policy
        }
        return measuring ? .measurement : .admitted
    }

    static func admitsLoad(
        enabled: Bool,
        mode: PlayerMode,
        demandBackend: Bool,
        path: MultiConnectionNetworkPath,
        primary: URL,
        cellularEnabled: Bool = false
    ) -> Bool {
        enabled && mode.usesOnlineVODServices && demandBackend
            && path.admits(cellularEnabled: cellularEnabled) && CDNHostPolicy.allows(primary)
    }

    /// API URLs retain their signed bytes; only catalogue entries swap authority.
    /// Tier 1 (verified API-signed URLs): distinct-host API backups first, then
    /// `primary` itself (exact signed URL). Tier 2 (synthetic mirror fallback):
    /// mainland UPOS catalogue hosts (one per provider first, then remaining).
    static func select(
        primary: URL,
        rawURLs: [String],
        catalogue: [CDNService] = CDNService.allCases,
        isExcluded: (String) -> Bool
    ) -> [URL] {
        guard CDNHostPolicy.allows(primary),
              let primaryHost = CDNHostPolicy.canonicalHost(primary.host())
        else { return [] }
        var seenHosts: Set<String> = []
        let overseasHosts = Set(CDNService.allCases.filter(\.isOverseas).compactMap(\.host))
        var candidates: [URL] = []
        func append(_ url: URL) {
            guard CDNHostPolicy.admitsTrustedVODHost(url),
                  let host = CDNHostPolicy.canonicalHost(url.host()),
                  host.hasPrefix("upos-"), host.hasSuffix(".bilivideo.com"),
                  !overseasHosts.contains(host),
                  !isExcluded(host), seenHosts.insert(host).inserted
            else { return }
            candidates.append(url)
        }
        // Tier 1a: distinct-host real API backup/base URLs first.
        for raw in rawURLs {
            guard let url = URL(string: raw),
                  let host = CDNHostPolicy.canonicalHost(url.host()),
                  host != primaryHost else { continue }
            append(url)
        }
        // Tier 1b: admit `primary` itself (exact signed URL already validated by open).
        append(primary)
        // Akamai signed objects cannot be moved into the UPOS mirror pool.
        guard primaryHost != "akamaized.net", !primaryHost.hasSuffix(".akamaized.net") else {
            return candidates
        }
        // Tier 2: synthetic mainland UPOS mirrors (provider-diverse first, then remaining).
        var providers: Set<CDNProvider> = []
        for service in catalogue where !service.isOverseas {
            guard let provider = service.provider, !providers.contains(provider),
                  let host = service.host,
                  let url = CDNHostPolicy.replacingAuthority(of: primary, withHost: host, scheme: "https")
            else { continue }
            let before = candidates.count
            append(url)
            if candidates.count > before { providers.insert(provider) }
        }
        for service in catalogue where !service.isOverseas {
            guard let host = service.host,
                  let url = CDNHostPolicy.replacingAuthority(of: primary, withHost: host, scheme: "https")
            else { continue }
            append(url)
        }
        return candidates
    }

    /// Canonical mainland UPOS hostnames present in the API's own signed playurl list.
    static func verifiedAPIHosts(rawURLs: [String]) -> Set<String> {
        let overseasHosts = Set(CDNService.allCases.filter(\.isOverseas).compactMap(\.host))
        var result: Set<String> = []
        for raw in rawURLs {
            guard let url = URL(string: raw),
                  CDNHostPolicy.admitsTrustedVODHost(url),
                  let host = CDNHostPolicy.canonicalHost(url.host()),
                  host.hasPrefix("upos-"), host.hasSuffix(".bilivideo.com"),
                  !overseasHosts.contains(host) else { continue }
            result.insert(host)
        }
        return result
    }
}

extension PlayerViewModel {
    func multiConnectionHelpers(primary: URL, rawURLs: [String]) -> [URL] {
        guard MultiConnectionVODCandidates.admitsLoad(
            enabled: MultiConnectionFeatureGate.isEnabled(),
            mode: mode,
            demandBackend: backendKind == .demandPaced,
            path: Self.multiConnectionNetworkPath,
            primary: primary,
            cellularEnabled: MultiConnectionFeatureGate.cellularEnabled()
        ) else { return [] }
        return MultiConnectionVODCandidates.select(primary: primary, rawURLs: rawURLs) {
            SmartCDNSelector.shared.excludesPrefetchHost($0)
        }
    }

    func beginMultiConnectionQuietWindow() -> UUID {
        let token = multiConnectionQuietWindows.beginProbe()
        refreshMultiConnectionQuiet()
        return token
    }

    func endMultiConnectionQuietWindow(_ token: UUID) {
        multiConnectionQuietWindows.endProbe(token)
        refreshMultiConnectionQuiet()
    }

    func refreshMultiConnectionQuiet() {
        publishMultiConnectionDisplay(rate: nil)
        resetMultiConnectionRate()
        // No backend work in the default-off path. Once active, disabling the
        // setting (a policy quiet) cancels the existing prefetcher's in-flight
        // pieces and holds it until the next load retires it.
        guard MultiConnectionFeatureGate.isEnabled() || multiConnectionWasEnabled else { return }
        guard mode.usesOnlineVODServices, backendKind == .demandPaced else { return }
        let enabled = MultiConnectionFeatureGate.isEnabled()
        multiConnectionWasEnabled = enabled
        backend.setMultiConnectionQuiet(MultiConnectionVODCandidates.prefetchQuiet(
            enabled: enabled, path: Self.multiConnectionNetworkPath,
            cellularEnabled: MultiConnectionFeatureGate.cellularEnabled(),
            loadClass: multiConnectionLoadClass, measuring: multiConnectionQuietWindows.isQuiet
        ))
    }

    /// The network class is resolved once per load; nil when no helper is admitted.
    func multiConnectionPolicyForLoad(hasHelpers: Bool) -> MultiConnectionPolicy? {
        let networkClass = Self.multiConnectionNetworkPath.networkClass
        guard hasHelpers, networkClass != .unavailable else {
            multiConnectionLoadClass = nil
            return nil
        }
        multiConnectionLoadClass = networkClass
        let apiHosts = MultiConnectionVODCandidates.verifiedAPIHosts(
            rawURLs: multiConnectionVideoURLs + multiConnectionAudioURLs
        )
        return MultiConnectionPolicy.make(networkClass: networkClass, verifiedAPIHosts: apiHosts)
    }
}
