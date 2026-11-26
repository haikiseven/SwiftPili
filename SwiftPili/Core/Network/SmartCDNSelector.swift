import Foundation
import Network
import Observation
import QuartzCore

@MainActor
final class CDNMeasurementActivity {
    private var observers: [UUID: (Bool) -> Void] = [:]
    private(set) var active = false
    private var sweepActive = false
    private var windows: Set<UUID> = []

    func addObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(active)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func beginWindow() -> UUID {
        let token = UUID()
        windows.insert(token)
        notify()
        return token
    }

    func endWindow(_ token: UUID) {
        windows.remove(token)
        notify()
    }

    func publish(_ active: Bool) {
        sweepActive = active
        notify()
    }

    private func notify() {
        active = sweepActive || !windows.isEmpty
        for observer in Array(observers.values) { observer(active) }
    }
}

final class CDNMeasurementObservation: Sendable {
    private let activity: CDNMeasurementActivity
    private let token: UUID

    @MainActor
    init(activity: CDNMeasurementActivity, observer: @escaping (Bool) -> Void) {
        self.activity = activity
        token = activity.addObserver(observer)
    }

    deinit {
        Task { @MainActor [activity, token] in activity.removeObserver(token) }
    }
}

@MainActor
@Observable
final class SmartCDNSelector {
    static let shared = SmartCDNSelector()
    @ObservationIgnored private var refreshOperation: UUID?

    init() {
        _ = Self.loadSeed()
    }

    private var selectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "smart_cdn_enabled")
    }

    struct HostProbe: Sendable {
        let address: String
        let latencyMs: Int
        let systemDNSFake: Bool
    }

    private struct SweepProbe: Sendable {
        let service: CDNService
        let host: String
        let ip: String
        let latencyMs: Int
        let systemDNSFake: Bool
    }

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smart_cdn_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smart_cdn_enabled") }
    }

    static var probeBudgetMB: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "smart_cdn_probe_budget_mb")
            return value > 0 ? min(max(value, 0.5), 8) : 2.0
        }
        set { UserDefaults.standard.set(min(max(newValue, 0.5), 8), forKey: "smart_cdn_probe_budget_mb") }
    }

    static var scaleProbeOnCellular: Bool {
        get { UserDefaults.standard.bool(forKey: "smart_cdn_scale_probe_cellular") }
        set { UserDefaults.standard.set(newValue, forKey: "smart_cdn_scale_probe_cellular") }
    }

    // MARK: - Cross-session seed host

    private struct SeedHost: Codable {
        let networkKey: String
        let host: String
        let kBps: Double
    }

    static let seedStorageKey = "smart_cdn_seed_host"

    private static func loadSeed() -> SeedHost? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: seedStorageKey),
              let decoded = try? JSONDecoder().decode(SeedHost.self, from: data),
              let host = CDNHostPolicy.canonicalHost(decoded.host),
              decoded.kBps.isFinite, decoded.kBps > 0 else {
            defaults.removeObject(forKey: seedStorageKey)
            return nil
        }
        return SeedHost(networkKey: decoded.networkKey, host: host, kBps: decoded.kBps)
    }

    private static func saveSeed(_ seed: SeedHost) {
        let defaults = UserDefaults.standard
        guard let host = CDNHostPolicy.canonicalHost(seed.host),
              seed.kBps.isFinite, seed.kBps > 0,
              let data = try? JSONEncoder().encode(
                  SeedHost(networkKey: seed.networkKey, host: host, kBps: seed.kBps)
              ) else {
            defaults.removeObject(forKey: seedStorageKey)
            return
        }
        defaults.set(data, forKey: seedStorageKey)
    }

    private static func logRejected(stage: String, host: String?, reason: String) {
        let diagHost = CDNHostPolicy.diagnosticHost(host)
        let diagReason = CDNHostPolicy.diagnosticReason(reason)
        PlayerLog.log("[SmartCDN] rejected stage=\(stage) host=\(diagHost) reason=\(diagReason)")
    }

    private static func networkKey(for client: ClientNetwork) -> String {
        "\(client.isp)|\(client.province)"
    }

    // MARK: - Models

    struct ClientNetwork: Sendable {
        let ip: String
        let isp: String
        let province: String
        let country: String

        var isPublicAddress: Bool { SmartCDNSelector.isPublicIP(ip) }
        var locationKnown: Bool { isPublicAddress && !country.isEmpty }

        var isMainland: Bool {
            guard country.contains("中国") || country == "CN" else { return false }
            let sar = ["香港", "澳门", "台湾"]
            return !sar.contains { country.contains($0) || province.contains($0) }
        }
    }

    nonisolated static func isPublicIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let (first, second) = (parts[0], parts[1])
        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 198, second == 18 || second == 19 { return false }
        return true
    }

    struct NodeReport: Sendable, Identifiable {
        let service: CDNService
        let host: String
        let ip: String
        let isp: String
        let province: String
        let latencyMs: Int
        let sameISP: Bool
        let sameProvince: Bool

        var id: String { host }

        var bucket: Int {
            if sameISP, sameProvince { return 0 }
            if sameISP { return 1 }
            if sameProvince { return 2 }
            return 3
        }
    }

    // MARK: - Observable state

    private(set) var client: ClientNetwork?
    private(set) var ranked: [NodeReport] = []
    private(set) var best: NodeReport?
    private(set) var isTesting = false
    @ObservationIgnored private let measurementActivity = CDNMeasurementActivity()

    func observeMeasurementActivity(_ observer: @escaping (Bool) -> Void) -> CDNMeasurementObservation {
        CDNMeasurementObservation(activity: measurementActivity, observer: observer)
    }

    func beginMeasurementWindow() -> UUID {
        measurementActivity.beginWindow()
    }

    func endMeasurementWindow(_ token: UUID) {
        measurementActivity.endWindow(token)
    }

    private(set) var lastTestAt: Date?
    private(set) var dnsServers: [String] = []
    private(set) var fakeIPDNSDetected = false
    private(set) var pathIsExpensive = false

    // MARK: - Blacklist

    private var blacklist: [String: Date] = [:]
    private let blacklistDuration: TimeInterval = 10 * 60

    private func isBlacklisted(_ host: String) -> Bool {
        guard let key = CDNHostPolicy.canonicalHost(host) else { return true }
        guard let until = blacklist[key] else { return false }
        if until > Date() { return true }
        blacklist[key] = nil
        return false
    }

    func excludesPrefetchHost(_ host: String) -> Bool {
        guard let key = CDNHostPolicy.canonicalHost(host) else { return true }
        return blacklist[key].map { $0 > Date() } ?? false
    }

    private func admittedHost(_ rawHost: String, stage: String) -> String? {
        let decision = CDNHostPolicy.decision(forHost: rawHost)
        guard let host = decision.canonicalHost else {
            Self.logRejected(stage: stage, host: rawHost, reason: decision.reason)
            return nil
        }
        return host
    }

    private func sanitizeRankedState() {
        let previousBest = best?.host
        ranked = ranked.compactMap { report in
            guard let host = CDNHostPolicy.canonicalHost(report.host) else { return nil }
            if host == report.host { return report }
            return NodeReport(
                service: report.service,
                host: host,
                ip: report.ip,
                isp: report.isp,
                province: report.province,
                latencyMs: report.latencyMs,
                sameISP: report.sameISP,
                sameProvince: report.sameProvince
            )
        }
        if let previousBest,
           let bestReport = ranked.first(where: {
               CDNHostPolicy.canonicalHost($0.host) == CDNHostPolicy.canonicalHost(previousBest)
                   && !isBlacklisted($0.host)
           }) {
            best = bestReport
        } else {
            best = ranked.first { !isBlacklisted($0.host) }
        }
    }

    func reportPlaybackIssue(host: String, reason: String) {
        guard let key = admittedHost(host, stage: "blacklist") else { return }
        mediaVerifiedHosts.remove(key)
        guard selectionEnabled else { return }
        blacklist[key] = Date().addingTimeInterval(blacklistDuration)
        let diagHost = CDNHostPolicy.diagnosticHost(key)
        let diagReason = CDNHostPolicy.diagnosticReason(reason)
        PlayerLog.log(
            "[SmartCDN] ⛔️ host=\(diagHost) blacklisted for \(Int(blacklistDuration / 60))min reason=\(diagReason)"
        )
        if CDNHostPolicy.canonicalHost(best?.host) == key {
            best = ranked.first { !isBlacklisted($0.host) }
            let nextDescription = best.map {
                "host=\(CDNHostPolicy.diagnosticHost($0.host)) bucket=\($0.bucket) latency=\($0.latencyMs)ms"
            } ?? "none left"
            PlayerLog.log("[SmartCDN] next best node: \(nextDescription)")
        }
    }

    // MARK: - Ramp knowledge

    private var rampEWMA: [String: (kBps: Double, samples: Int)] = [:]
    private var sweepReachableHosts: Set<String> = []
    private var mediaVerifiedHosts: Set<String> = []

    func recordMediaReachable(host: String) {
        guard let key = admittedHost(host, stage: "media-reachability"),
              !isBlacklisted(key) else { return }
        mediaVerifiedHosts.insert(key)
    }

    func hasSessionReachabilityEvidence(for host: String) -> Bool {
        guard let key = admittedHost(host, stage: "reachability-evidence"),
              !isBlacklisted(key) else { return false }
        if let entry = rampEWMA[key], entry.samples >= 1 { return true }
        return mediaVerifiedHosts.contains(key)
    }

    func measuredRamp(for host: String) -> Int? {
        guard let key = admittedHost(host, stage: "ramp-read"),
              let entry = rampEWMA[key], entry.samples >= 1 else { return nil }
        return Int(entry.kBps)
    }

    func rankedHosts(limit: Int) -> [String] {
        sanitizeRankedState()
        return Array(ranked.prefix(max(0, limit)).compactMap { CDNHostPolicy.canonicalHost($0.host) })
    }

    var preferThroughput = false {
        didSet {
            guard preferThroughput != oldValue, !ranked.isEmpty else { return }
            sanitizeRankedState()
            ranked = sortByPreference(ranked)
            best = ranked.first { !isBlacklisted($0.host) }
        }
    }

    private var seedApplied = false

    func recordRamp(
        host: String,
        kBps: Int,
        verdict: CDNProbeVerdict = .complete
    ) {
        guard CDNProbeVerdictPolicy.isHealthy(verdict),
              selectionEnabled,
              let key = admittedHost(host, stage: "ramp"),
              kBps > 0 else { return }
        let previous = rampEWMA[key].flatMap { $0.samples > 0 ? $0 : nil }
        let value = previous.map { $0.kBps * 0.65 + Double(kBps) * 0.35 } ?? Double(kBps)
        rampEWMA[key] = (value, (previous?.samples ?? 0) + 1)
        reRankForRamp()
        persistSeed()
    }

    private func persistSeed() {
        guard let client,
              let top = rampEWMA.filter({ $0.value.samples >= 2 })
                  .max(by: { $0.value.kBps < $1.value.kBps }) else { return }
        Self.saveSeed(
            SeedHost(networkKey: Self.networkKey(for: client), host: top.key, kBps: top.value.kBps)
        )
    }

    private func applySeedHost() {
        guard selectionEnabled, ranked.isEmpty, let seed = Self.loadSeed(),
              let service = (CDNNodeCatalog.mainlandServices + CDNNodeCatalog.overseasServices).first(where: {
                  CDNHostPolicy.canonicalHost($0.host) == seed.host
              }) else { return }
        if rampEWMA[seed.host] == nil {
            rampEWMA[seed.host] = (seed.kBps, 0)
        }
        let report = NodeReport(
            service: service,
            host: seed.host,
            ip: "",
            isp: "",
            province: "",
            latencyMs: 0,
            sameISP: false,
            sameProvince: false
        )
        ranked = [report]
        best = report
        seedApplied = true
        let mbps = String(format: "%.1f", seed.kBps / 1024)
        PlayerLog.log("[SmartCDN] 🌱 seeded \(seed.host) (\(mbps)MB/s from last session) — sweep will validate")
    }

    private func rampTier(_ host: String, bestKBps: Double) -> Int {
        guard bestKBps > 0, let entry = rampEWMA[host], entry.samples >= 2 else { return 1 }
        if entry.kBps * 1.3 >= bestKBps { return 0 }
        if entry.kBps * 2 >= bestKBps { return 1 }
        return 2
    }

    private func reRankForRamp() {
        guard !ranked.isEmpty else { return }
        sanitizeRankedState()
        let previous = best?.host
        ranked = sortByPreference(ranked)
        best = ranked.first { !isBlacklisted($0.host) }
        if previous != best?.host {
            let detail = rampEWMA
                .map { entry in
                    let label = entry.key.split(separator: ".").first ?? "?"
                    let mbps = String(format: "%.1f", entry.value.kBps / 1024)
                    return "\(label)=\(mbps)MBps(n=\(entry.value.samples))"
                }
                .joined(separator: " ")
            PlayerLog.log(
                "[SmartCDN] 🐢 ramp re-rank moved selection: \(previous ?? "none") → \(best?.host ?? "none") | \(detail)"
            )
        }
    }

    // MARK: - Playback hooks

    func nodeForPlayback() -> NodeReport? {
        guard selectionEnabled else { return nil }
        sanitizeRankedState()
        guard let best, !isBlacklisted(best.host) else { return nil }
        return best
    }

    var hasRanking: Bool {
        sanitizeRankedState()
        return !ranked.isEmpty
    }

    func failoverServices(excluding excludedHost: String?) -> [CDNService] {
        guard selectionEnabled else { return [] }
        sanitizeRankedState()
        let excludedKey = excludedHost.flatMap(CDNHostPolicy.canonicalHost)
        return ranked
            .filter {
                guard let host = CDNHostPolicy.canonicalHost($0.host) else { return false }
                return host != excludedKey && !isBlacklisted(host)
            }
            .map(\.service)
    }

    // MARK: - Cache lifecycle

    func invalidateCache(reason: String, dropSeed: Bool = true) {
        lastFullSweepAt = 0
        refreshOperation = nil
        if dropSeed {
            UserDefaults.standard.removeObject(forKey: Self.seedStorageKey)
        }
        guard client != nil || best != nil || !ranked.isEmpty || !rampEWMA.isEmpty
            || !sweepReachableHosts.isEmpty || !mediaVerifiedHosts.isEmpty
            || !blacklist.isEmpty else { return }
        PlayerLog.log("[SmartCDN] cache invalidated reason=\(CDNHostPolicy.diagnosticReason(reason))")
        client = nil
        ranked = []
        best = nil
        lastTestAt = nil
        fakeIPDNSDetected = false
        rampEWMA = [:]
        sweepReachableHosts = []
        mediaVerifiedHosts = []
        blacklist = [:]
        seedApplied = false
    }

    // MARK: - Network change awareness

    private let pathMonitor = NWPathMonitor()
    private var monitoringStarted = false
    private var pathSignature: String?
    private var retestDebounce: Task<Void, Never>?

    func launch() {
        startPathMonitorIfNeeded()
        _ = Self.loadSeed()
        guard selectionEnabled else {
            PlayerLog.log("[SmartCDN] disabled — no launch pre-test")
            return
        }
        applySeedHost()
        Task { await warmUp(trigger: "app launch") }
    }

    private func startPathMonitorIfNeeded() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            var active: [String] = []
            if path.usesInterfaceType(.wifi) { active.append("wifi") }
            if path.usesInterfaceType(.cellular) { active.append("cellular") }
            if path.usesInterfaceType(.wiredEthernet) { active.append("wired") }
            if path.usesInterfaceType(.other) { active.append("other") }
            let signature = active.isEmpty ? "none" : active.joined(separator: "+")
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.pathIsExpensive = expensive
                self?.handlePathChange(signature: signature, satisfied: path.status == .satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.swiftpili.smartcdn.path"))
    }

    private func handlePathChange(signature: String, satisfied: Bool) {
        let previous = pathSignature
        pathSignature = signature
        guard let previous, previous != signature else { return }
        PlayerLog.log("[SmartCDN] network path changed: \(previous) → \(signature) (satisfied=\(satisfied))")
        invalidateCache(reason: "network change", dropSeed: false)
        guard selectionEnabled, satisfied else { return }
        retestDebounce?.cancel()
        retestDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.warmUp(trigger: "network change", force: true)
        }
    }

    func refreshClientNetwork(trigger: String) async {
        guard selectionEnabled, !isTesting else { return }
        let sweepTicket = lastFullSweepAt
        let operation = UUID()
        refreshOperation = operation
        defer {
            if refreshOperation == operation { refreshOperation = nil }
        }
        let detected = await Self.detectClientNetwork()
        guard selectionEnabled, !isTesting, refreshOperation == operation,
              lastFullSweepAt == sweepTicket else { return }
        guard let detected else {
            PlayerLog.log("[SmartCDN] client refresh (\(trigger)) failed — keeping \(client?.ip ?? "none")")
            return
        }
        let previous = client?.ip
        if let previous, previous != detected.ip {
            PlayerLog.log(
                "[SmartCDN] client refresh (\(trigger)): IP \(previous) → \(detected.ip) — forcing full re-test"
            )
            invalidateCache(reason: "public IP changed", dropSeed: false)
            await warmUp(trigger: "\(trigger): IP changed", force: true)
        } else {
            client = detected
            PlayerLog.log(
                "[SmartCDN] client refresh (\(trigger)): \(detected.ip) (\(detected.isp)/\(detected.province))"
            )
        }
    }

    // MARK: - Sweep

    private var lastFullSweepAt: TimeInterval = 0
    private let minRetestInterval: TimeInterval = 5 * 60
    private var geoCache: [String: (isp: String, province: String)] = [:]

    func warmUp(trigger: String, force: Bool = false) async {
        guard selectionEnabled else { return }
        guard !isTesting else {
            PlayerLog.log("[SmartCDN] sweep already running — skipping (\(trigger))")
            return
        }
        let now = CACurrentMediaTime()
        if !force, lastFullSweepAt > 0, now - lastFullSweepAt < minRetestInterval {
            let age = Int(now - lastFullSweepAt)
            PlayerLog.log(
                "[SmartCDN] throttled: last sweep \(age)s ago (<\(Int(minRetestInterval))s) — skipping (\(trigger))"
            )
            return
        }
        lastFullSweepAt = now
        refreshOperation = nil
        isTesting = true
        measurementActivity.publish(true)
        sweepReachableHosts = []
        defer {
            isTesting = false
            measurementActivity.publish(false)
        }
        PlayerLog.log("[SmartCDN] sweep started (\(trigger))")

        dnsServers = Self.systemDNSServers()
        PlayerLog.log(
            "[SmartCDN] DNS server(s): \(dnsServers.isEmpty ? "unknown" : dnsServers.joined(separator: ", "))"
        )

        let previousIP = client?.ip
        let detected = await Self.detectClientNetwork()
        guard selectionEnabled, lastFullSweepAt == now else { return }
        client = detected
        if seedApplied {
            seedApplied = false
            if let detected, let seed = Self.loadSeed(),
               Self.networkKey(for: detected) != seed.networkKey {
                PlayerLog.log("[SmartCDN] seed \(seed.host) was for a different network — dropping its ramp")
                if rampEWMA[seed.host]?.samples == 0 { rampEWMA[seed.host] = nil }
            }
        }
        if let detected {
            PlayerLog.log(
                "[SmartCDN] client: ip=\(detected.ip) isp=\(detected.isp) "
                    + "province=\(detected.province) country=\(detected.country) mainland=\(detected.isMainland)"
            )
            if let previousIP, previousIP != detected.ip {
                PlayerLog.log("[SmartCDN] public IP changed (\(previousIP) → \(detected.ip)) — old ranking discarded")
                ranked = []
                best = nil
                rampEWMA = [:]
            }
        } else {
            PlayerLog.log("[SmartCDN] ⚠️ client network detection failed — ranking will be latency-only")
        }

        let mainland: Bool? = {
            guard let detected, detected.locationKnown else { return nil }
            return detected.isMainland
        }()
        let pool: [CDNService] = switch mainland {
        case .some(true): CDNNodeCatalog.mainlandServices
        case .some(false): CDNNodeCatalog.overseasServices
        case nil: CDNNodeCatalog.mainlandServices + CDNNodeCatalog.overseasServices
        }
        if mainland == nil {
            PlayerLog.log("[SmartCDN] location unknown/untrusted — testing mainland AND overseas pools")
        }
        let candidates = pool.filter { service in
            guard let admitted = service.host.flatMap(CDNHostPolicy.canonicalHost) else { return false }
            return !isBlacklisted(admitted)
        }
        let skipped = pool.count - candidates.count
        if skipped > 0 {
            PlayerLog.log("[SmartCDN] \(skipped) node(s) currently blacklisted — not probed")
        }

        let probes = await withTaskGroup(of: SweepProbe?.self, returning: [SweepProbe].self) { group in
            for service in candidates {
                guard let host = service.host.flatMap(CDNHostPolicy.canonicalHost) else { continue }
                group.addTask {
                    guard let probe = await Self.probeHost(host) else { return nil }
                    return SweepProbe(
                        service: service,
                        host: host,
                        ip: probe.address,
                        latencyMs: probe.latencyMs,
                        systemDNSFake: probe.systemDNSFake
                    )
                }
            }
            var results: [SweepProbe] = []
            for await probe in group {
                if let probe { results.append(probe) }
            }
            return results
        }
        guard selectionEnabled, lastFullSweepAt == now else { return }
        fakeIPDNSDetected = probes.contains { $0.systemDNSFake }
        if fakeIPDNSDetected {
            PlayerLog.log("[SmartCDN] fake-IP VPN DNS detected — node IPs recovered via DoH where possible")
        }
        guard !probes.isEmpty else {
            PlayerLog.log(
                "[SmartCDN] ⚠️ sweep found no reachable node out of \(candidates.count) — keeping previous selection"
            )
            lastTestAt = Date()
            return
        }

        let fakeIPs = Set(probes.map(\.ip)).filter { !Self.isPublicIP($0) }
        if !fakeIPs.isEmpty {
            PlayerLog.log(
                "[SmartCDN] ⚠️ \(fakeIPs.count) node IP(s) still in reserved ranges after DoH — latency-only for those"
            )
        }
        let unknownIPs = Set(probes.map(\.ip)).filter { geoCache[$0] == nil && Self.isPublicIP($0) }
        if !unknownIPs.isEmpty {
            let looked = await withTaskGroup(
                of: (ip: String, isp: String, province: String)?.self,
                returning: [(ip: String, isp: String, province: String)].self
            ) { group in
                for ip in unknownIPs {
                    group.addTask {
                        guard let info = await Self.geolocate(ip: ip) else { return nil }
                        return (ip, info.isp, info.province)
                    }
                }
                var results: [(ip: String, isp: String, province: String)] = []
                for await entry in group {
                    if let entry { results.append(entry) }
                }
                return results
            }
            guard selectionEnabled, lastFullSweepAt == now else { return }
            for entry in looked {
                geoCache[entry.ip] = (entry.isp, entry.province)
            }
        }

        let clientISP = Self.normalizeISP(detected?.isp ?? "")
        let clientProvince = Self.normalizeRegion(detected?.province ?? "")
        installValidatedSweepReports(probes.map { probe in
            let geo = geoCache[probe.ip]
            let nodeISP = Self.normalizeISP(geo?.isp ?? "")
            let nodeProvince = Self.normalizeRegion(geo?.province ?? "")
            return NodeReport(
                service: probe.service,
                host: probe.host,
                ip: probe.ip,
                isp: geo?.isp ?? "",
                province: geo?.province ?? "",
                latencyMs: probe.latencyMs,
                sameISP: !clientISP.isEmpty && !nodeISP.isEmpty && nodeISP == clientISP,
                sameProvince: !clientProvince.isEmpty && !nodeProvince.isEmpty && nodeProvince == clientProvince
            )
        })
        lastTestAt = Date()

        for node in ranked {
            let provider = node.service.provider?.rawValue ?? "?"
            let isp = node.isp.isEmpty ? "?" : node.isp
            let province = node.province.isEmpty ? "?" : node.province
            let flags = (node.sameISP ? " [same ISP]" : "") + (node.sameProvince ? " [same province]" : "")
            PlayerLog.log(
                "[SmartCDN]   #\(node.bucket) \(node.host) provider=\(provider) "
                    + "ip=\(node.ip) \(node.latencyMs)ms isp=\(isp) province=\(province)\(flags)"
            )
        }
        if let best {
            let provider = best.service.provider?.rawValue ?? "?"
            PlayerLog.log(
                "[SmartCDN] ✅ selected \(best.host) (\(best.ip)) — bucket \(best.bucket), "
                    + "provider \(provider), \(best.latencyMs)ms"
            )
        }
    }

    func installValidatedSweepReports(_ reports: [NodeReport]) {
        sweepReachableHosts = Set(reports.compactMap { CDNHostPolicy.canonicalHost($0.host) })
        guard !sweepReachableHosts.isEmpty else { return }
        ranked = sortByPreference(reports)
        sanitizeRankedState()
        best = ranked.first { !isBlacklisted($0.host) }
    }

    private func sortByPreference(_ nodes: [NodeReport]) -> [NodeReport] {
        let admitted = nodes.filter { CDNHostPolicy.allowsHost($0.host) }
        let rank = CDNProvider.rankTable
        func providerRank(_ node: NodeReport) -> Int {
            node.service.provider.flatMap { rank[$0] } ?? Int.max
        }
        let bestKBps = rampEWMA.values.filter { $0.samples >= 2 }.map(\.kBps).max() ?? 0
        return admitted.sorted {
            let (tier0, tier1) = (rampTier($0.host, bestKBps: bestKBps), rampTier($1.host, bestKBps: bestKBps))
            if preferThroughput {
                if tier0 != tier1 { return tier0 < tier1 }
                if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
            } else {
                if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
                if tier0 != tier1 { return tier0 < tier1 }
            }
            let (rank0, rank1) = (providerRank($0), providerRank($1))
            if rank0 != rank1 { return rank0 < rank1 }
            return $0.latencyMs < $1.latencyMs
        }
    }

    func providerPriorityChanged() {
        sanitizeRankedState()
        let order = CDNProvider.priority.map(\.rawValue).joined(separator: " > ")
        PlayerLog.log("[SmartCDN] provider priority changed → \(order)")
        guard !ranked.isEmpty else { return }
        let previous = best?.host
        ranked = sortByPreference(ranked)
        best = ranked.first { !isBlacklisted($0.host) }
        if previous != best?.host {
            PlayerLog.log("[SmartCDN] re-rank moved selection: \(previous ?? "none") → \(best?.host ?? "none")")
        } else {
            PlayerLog.log("[SmartCDN] re-rank kept selection: \(previous ?? "none")")
        }
    }

    // MARK: - Detection helpers

    private nonisolated static func probeHost(_ host: String) async -> HostProbe? {
        let system = await resolveIP(host: host)
        let systemFake = system.map { !isPublicIP($0) } ?? false
        var ip = system
        if system == nil || systemFake {
            if let real = await resolveIPViaDoH(host: host) {
                let flag = systemFake ? " (fake-IP)" : ""
                PlayerLog.log("[SmartCDN] \(host): system DNS → \(system ?? "failed")\(flag) — DoH → \(real)")
                ip = real
            }
        }
        guard let ip else {
            PlayerLog.log("[SmartCDN] \(host): DNS resolution failed (system AND DoH)")
            return nil
        }
        guard let latencyMs = await probeLatencyMs(host: host) else {
            PlayerLog.log("[SmartCDN] \(host) (\(ip)): unreachable")
            return nil
        }
        return HostProbe(address: ip, latencyMs: latencyMs, systemDNSFake: systemFake)
    }

    private struct ZoneInfo: Decodable, Sendable {
        let addr: String?
        let isp: String?
        let province: String?
        let country: String?
    }

    private static func detectClientNetwork() async -> ClientNetwork? {
        var candidate: ClientNetwork?
        do {
            let zone = try await BiliAPIClient.shared.request(
                BiliEndpoint(path: "/x/web-interface/zone"),
                type: ZoneInfo.self
            )
            if let ip = zone.addr, !ip.isEmpty {
                candidate = ClientNetwork(
                    ip: ip,
                    isp: zone.isp ?? "",
                    province: zone.province ?? "",
                    country: zone.country ?? ""
                )
            }
        } catch {
            PlayerLog.log("[SmartCDN] ⚠️ zone lookup failed: \(error)")
        }

        if let candidate, candidate.isPublicAddress { return candidate }
        if let candidate {
            PlayerLog.log("[SmartCDN] ⚠️ zone reported reserved address \(candidate.ip) — asking live getIpInfo")
        }

        do {
            let info = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/xlive/web-room/v1/index/getIpInfo",
                    baseURL: "https://api.live.bilibili.com"
                ),
                type: IPAddrInfo.self
            )
            if let ip = info.addr, !ip.isEmpty {
                let second = ClientNetwork(
                    ip: ip,
                    isp: info.isp ?? "",
                    province: info.province ?? "",
                    country: info.country ?? ""
                )
                if second.isPublicAddress || candidate == nil { return second }
            }
        } catch {
            PlayerLog.log("[SmartCDN] ⚠️ getIpInfo lookup failed: \(error)")
        }
        return candidate
    }

    private struct IPAddrInfo: Decodable, Sendable {
        let addr: String?
        let isp: String?
        let province: String?
        let country: String?
    }

    private static func geolocate(ip: String) async -> (isp: String, province: String)? {
        do {
            let info = try await BiliAPIClient.shared.request(
                BiliEndpoint(
                    path: "/ip_service/v1/ip_service/get_ip_addr",
                    params: ["ip": ip],
                    baseURL: "https://api.live.bilibili.com"
                ),
                type: IPAddrInfo.self
            )
            return (info.isp ?? "", info.province ?? "")
        } catch {
            PlayerLog.log("[SmartCDN] ⚠️ geolocate \(ip) failed: \(error)")
            return nil
        }
    }

    private nonisolated static func systemDNSServers() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/etc/resolv.conf")),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "nameserver" else { return nil }
            return String(parts[1])
        }
    }

    private nonisolated static let dnsQueue = DispatchQueue(
        label: "com.swiftpili.smartcdn.dns",
        attributes: .concurrent
    )

    private nonisolated static func resolveIP(host: String) async -> String? {
        guard CDNHostPolicy.allowsHost(host) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            dnsQueue.async {
                var hints = addrinfo(
                    ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                    ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                    ai_addr: nil, ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(
                    first.pointee.ai_addr, first.pointee.ai_addrlen,
                    &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
                ) == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                continuation.resume(returning: String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    private nonisolated static func resolveIPViaDoH(host: String) async -> String? {
        guard CDNHostPolicy.allowsHost(host) else { return nil }
        let endpoints = [
            "https://223.5.5.5/resolve?name=\(host)&type=1",
            "https://8.8.8.8/resolve?name=\(host)&type=1",
        ]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 4
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let answers = json["Answer"] as? [[String: Any]] else { continue }
                for answer in answers {
                    if (answer["type"] as? Int) == 1,
                       let ip = answer["data"] as? String, isPublicIP(ip) {
                        return ip
                    }
                }
            } catch {
                PlayerLog.log("[SmartCDN] DoH \(url.host ?? "?") failed for \(host): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private nonisolated static func probeLatencyMs(host: String) async -> Int? {
        guard CDNHostPolicy.allowsHost(host) else { return nil }
        guard let url = URL(string: "https://\(host)/") else { return nil }
        var best: Int?
        for _ in 1...2 {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.setValue(BiliAPIClient.defaultReferer, forHTTPHeaderField: "Referer")
            let start = CACurrentMediaTime()
            do {
                let (_, response) = try await session.data(for: request)
                guard response is HTTPURLResponse else { continue }
                let ms = Int((CACurrentMediaTime() - start) * 1000)
                best = min(best ?? .max, ms)
            } catch {
                continue
            }
        }
        return best
    }

    // MARK: - Matching normalization

    private nonisolated static func normalizeRegion(_ raw: String) -> String {
        var region = raw.trimmingCharacters(in: .whitespaces)
        let suffixes = ["维吾尔自治区", "壮族自治区", "回族自治区", "特别行政区", "自治区", "省", "市"]
        for suffix in suffixes where region.hasSuffix(suffix) {
            region = String(region.dropLast(suffix.count))
            break
        }
        return region
    }

    private nonisolated static func normalizeISP(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("电信") || lower.contains("chinanet") || lower.contains("telecom") { return "telecom" }
        if lower.contains("联通") || lower.contains("unicom") { return "unicom" }
        if lower.contains("移动") || lower.contains("铁通") || lower.contains("mobile") || lower.contains("cmcc") {
            return "mobile"
        }
        if lower.contains("广电") || lower.contains("cbn") { return "cbn" }
        if lower.contains("教育") || lower.contains("cernet") { return "cernet" }
        return lower.trimmingCharacters(in: .whitespaces)
    }
}
