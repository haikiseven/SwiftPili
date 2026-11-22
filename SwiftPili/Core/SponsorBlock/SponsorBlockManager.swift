import Foundation
import Observation

/// Central state + settings for the SponsorBlock feature. Mirrors the shape
/// of `BlocklistManager`: an `@Observable` singleton the player and the
/// settings screen both read.
///
/// The player consults `segments`, `action(for:)`, and the skip helpers on
/// its clock tick; the settings screen binds the persisted preferences.
/// `isEnabled` is the single global switch — off means no fetch, no skip,
/// no bar coloring, no submitting.
@MainActor
@Observable
final class SponsorBlockManager {
    static let shared = SponsorBlockManager()

    private enum Key {
        static let enabled = "sponsorblock_enabled"
        static let actions = "sponsorblock_category_actions"
        static let server = "sponsorblock_server"
        static let showOnBar = "sponsorblock_show_on_bar"
        static let showNotice = "sponsorblock_show_notice"
        static let userID = "sponsorblock_user_id"
        static let skipCount = "sponsorblock_skip_count"
        static let skipSeconds = "sponsorblock_skip_seconds"
        static let minVotes = "sponsorblock_min_votes"
    }

    // MARK: Global switch

    /// The single master button. Off = the whole feature is inert.
    var isEnabled: Bool = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            if !isEnabled { clear() }
        }
    }

    // MARK: Preferences

    /// Draw the segments as colored bands on the scrubber.
    var showOnProgressBar: Bool = UserDefaults.standard.object(forKey: Key.showOnBar) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showOnProgressBar, forKey: Key.showOnBar) }
    }

    /// Show a "Skipped …" toast when a segment auto-skips.
    var showSkipNotice: Bool = UserDefaults.standard.object(forKey: Key.showNotice) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSkipNotice, forKey: Key.showNotice) }
    }

    /// Empty = the default `bsbsb.top`. Any override is passed through to
    /// the service verbatim (scheme is added if missing).
    var customServer: String = UserDefaults.standard.string(forKey: Key.server) ?? "" {
        didSet { UserDefaults.standard.set(customServer, forKey: Key.server) }
    }

    /// Minimum community score a segment needs to be used (drawn / skipped).
    /// The server already withholds anything ≤ −2 (removed), so the useful
    /// range is: −1 = include the server's floor (down-voted), 0 = hide
    /// down-voted, 1 = only up-voted. `locked` (VIP) segments always pass.
    /// Default −1 keeps the pre-setting behavior. Applied at fetch time; a
    /// change refetches the current video so it takes effect immediately.
    var minVotes: Int = UserDefaults.standard.object(forKey: Key.minVotes) as? Int ?? -1 {
        didSet {
            UserDefaults.standard.set(minVotes, forKey: Key.minVotes)
            reloadRequestedSource()
        }
    }

    /// Private user ID — required to submit or vote. Generated lazily so a
    /// user who never contributes never creates one.
    var privateUserID: String = UserDefaults.standard.string(forKey: Key.userID) ?? "" {
        didSet { UserDefaults.standard.set(privateUserID, forKey: Key.userID) }
    }

    // MARK: Per-category actions

    private var actions: [SponsorCategory: SponsorAction] = SponsorBlockManager.loadActions()

    func action(for category: SponsorCategory) -> SponsorAction {
        actions[category] ?? category.defaultAction
    }

    func setAction(_ action: SponsorAction, for category: SponsorCategory) {
        actions[category] = action
        persistActions()
        // A newly enabled/disabled category changes what should be on the
        // bar and skipped — refetch the current video if one is loaded.
        reloadRequestedSource()
    }

    /// Categories that aren't `.disabled` — the set actually fetched/drawn.
    private var activeCategories: [SponsorCategory] {
        SponsorCategory.allCases.filter { action(for: $0) != .disabled }
    }

    // MARK: Stats

    private(set) var skippedCount: Int = UserDefaults.standard.integer(forKey: Key.skipCount)
    private(set) var skippedSeconds: Double = UserDefaults.standard.double(forKey: Key.skipSeconds)

    // MARK: Loaded segments

    private struct Source: Equatable {
        let videoID: String
        let cid: Int?
    }

    private struct PublishedSegments {
        let source: Source
        let segments: [SponsorSegment]
    }

    /// Source and payload change together; a pending source is never the
    /// identity of the previous part's retained intervals.
    private var published: PublishedSegments?
    var segments: [SponsorSegment] { published?.segments ?? [] }
    var loadedVideoID: String? { published?.source.videoID }
    var loadedCID: Int? { published?.source.cid }
    private(set) var isLoading = false
    @ObservationIgnored private var requestedSource: Source?
    @ObservationIgnored private var requestSerial: UInt64 = 0

    private init() {}

    // MARK: Loading

    /// Fetches segments for a video. No-op (and clears) when the feature is
    /// off or there are no active categories. Safe to call on every load;
    /// a repeat call for the same identity still refetches (settings may
    /// have changed).
    func load(videoID: String, cid: Int?) async {
        guard !Task.isCancelled else { return }
        guard isEnabled else { clear(); return }
        let source = Source(videoID: videoID, cid: cid)
        requestSerial &+= 1
        let serial = requestSerial
        requestedSource = source
        if published?.source != source { published = nil }
        let categories = activeCategories
        guard !categories.isEmpty else {
            published = nil
            isLoading = false
            return
        }
        let server = customServer
        let minimumScore = minVotes

        isLoading = true
        defer {
            if requestSerial == serial { isLoading = false }
        }

        PlayerLog.log("[SponsorBlock] fetch \(videoID) cid=\(cid.map(String.init) ?? "-") " +
            "categories=[\(categories.map(\.apiValue).joined(separator: ","))] " +
            "server=\(server.isEmpty ? "bsbsb.top" : server)")

        do {
            let result = try await SponsorBlockService.shared.fetchSegments(
                videoID: videoID, cid: cid, categories: categories, server: server
            )
            guard !Task.isCancelled, requestSerial == serial, requestedSource == source else { return }
            // Drop segments below the score threshold (locked/VIP always
            // pass). The server floor is −1, so higher thresholds hide the
            // down-voted / unvoted bands.
            let kept = result.filter { $0.locked || $0.votes >= minimumScore }
            let dropped = result.count - kept.count
            published = PublishedSegments(source: source, segments: kept.sorted { $0.start < $1.start })
            // Always log the outcome — including 0 — and each segment's
            // RESOLVED action + score, so a "why didn't it skip?" is
            // answerable at a glance: `intro[manual,v0]` means button-only,
            // `filler[disabled,v3]` off, `sponsor[skip,v-1]` down-voted.
            if segments.isEmpty {
                PlayerLog.log("[SponsorBlock] 0 segments for \(videoID) cid=\(cid.map(String.init) ?? "-")" +
                    (dropped > 0 ? " (\(dropped) below score \(minimumScore))" : ""))
            } else {
                PlayerLog.log("[SponsorBlock] \(segments.count) segment(s) for \(videoID)" +
                    (dropped > 0 ? " (\(dropped) below score \(minimumScore))" : "") + ": " +
                    segments.map { "\($0.category.apiValue)[\(action(for: $0.category).rawValue),v\($0.votes)\($0.locked ? ",locked" : "")] \(Int($0.start))-\(Int($0.end))s\($0.isPOI ? " POI" : "")" }
                    .joined(separator: ", "))
            }
        } catch {
            guard !Task.isCancelled, requestSerial == serial, requestedSource == source else { return }
            PlayerLog.log("[SponsorBlock] fetch failed for \(videoID): \(error)")
            published = nil
        }
    }

    /// Drops the current video's segments (player stop / feature off).
    func clear() {
        requestSerial &+= 1
        requestedSource = nil
        published = nil
        isLoading = false
    }

    private func reloadRequestedSource() {
        guard let source = requestedSource else { return }
        let serial = requestSerial
        Task { [weak self] in
            guard let self, self.requestSerial == serial, self.requestedSource == source else { return }
            await self.load(videoID: source.videoID, cid: source.cid)
        }
    }

    // MARK: Skip evaluation (called from the player tick)

    /// A segment to auto-skip past: playback is inside a `.skip` range
    /// (not a POI) we haven't already skipped this session.
    ///
    /// The tail guard is a small fixed 0.3s — just enough to avoid a
    /// pointless micro-seek when the playhead is already at the very end —
    /// NOT the 1.5s the anime OP/ED path uses. A 1.5s guard made short
    /// SponsorBlock segments (2–4s interaction / 三连 reminders, and
    /// anything ≤1.5s) unskippable: their [start, end−1.5) window is tiny
    /// or empty, so a clock tick would routinely miss it. That was the main
    /// cause of "sometimes doesn't skip".
    func autoSkipSegment(at time: Double, excluding skipped: Set<String>) -> SponsorSegment? {
        guard isEnabled else { return nil }
        return segments.first { seg in
            !seg.isPOI
                && action(for: seg.category) == .skip
                && !skipped.contains(seg.uuid)
                && time >= seg.start
                && time < seg.end - 0.3
        }
    }

    /// The `.manual` range currently under the playhead, for the on-screen
    /// "Skip …" button. POIs are markers only, not offered here.
    func manualSegment(at time: Double) -> SponsorSegment? {
        guard isEnabled else { return nil }
        return segments.first { seg in
            !seg.isPOI
                && action(for: seg.category) == .manual
                && time >= seg.start
                && time < seg.end - 0.5
        }
    }

    /// The `.mute` range currently under the playhead. Unlike skip there is
    /// no tail guard — audio stays muted through the whole range, restored
    /// only once playback leaves it.
    func muteSegment(at time: Double) -> SponsorSegment? {
        guard isEnabled else { return nil }
        return segments.first { seg in
            !seg.isPOI
                && action(for: seg.category) == .mute
                && time >= seg.start
                && time < seg.end
        }
    }

    /// Segments to draw on the scrubber (excludes POIs, which are drawn as
    /// point markers via `poiMarkers`).
    var barSegments: [SponsorSegment] {
        guard isEnabled, showOnProgressBar else { return [] }
        return segments.filter { !$0.isPOI }
    }

    var poiMarkers: [SponsorSegment] {
        guard isEnabled, showOnProgressBar else { return [] }
        return segments.filter { $0.isPOI }
    }

    // MARK: Stats + telemetry

    func recordSkip(seconds: Double, uuid: String) {
        skippedCount += 1
        skippedSeconds += max(0, seconds)
        UserDefaults.standard.set(skippedCount, forKey: Key.skipCount)
        UserDefaults.standard.set(skippedSeconds, forKey: Key.skipSeconds)
        let server = customServer
        Task { await SponsorBlockService.shared.reportViewed(uuid: uuid, server: server) }
    }

    /// A mute doesn't shorten the video, so it isn't counted toward the
    /// skip stats — but it's still a segment the user "consumed", so the
    /// view is reported for the server's counts.
    func recordMute(uuid: String) {
        let server = customServer
        Task { await SponsorBlockService.shared.reportViewed(uuid: uuid, server: server) }
    }

    func resetStats() {
        skippedCount = 0
        skippedSeconds = 0
        UserDefaults.standard.set(0, forKey: Key.skipCount)
        UserDefaults.standard.set(0.0, forKey: Key.skipSeconds)
    }

    // MARK: User ID

    /// Returns the existing private ID, generating and persisting one on
    /// first use. The public leaderboard ID (SHA-256 ×5000) is never needed
    /// client-side, so it isn't computed.
    @discardableResult
    func ensureUserID() -> String {
        if privateUserID.count >= 30 { return privateUserID }
        // 40 hex chars — comfortably over the 30-char server minimum.
        let generated = (0 ..< 40).map { _ in "0123456789abcdef".randomElement()! }
        privateUserID = String(generated)
        return privateUserID
    }

    // MARK: Contributions

    func submit(
        start: Double,
        end: Double,
        category: SponsorCategory,
        actionType: SponsorActionType,
        videoDuration: Double
    ) async throws {
        // A user can contribute even when the optional segment GET failed;
        // the intended source is independent of the published interval set.
        guard let source = requestedSource else { throw SponsorBlockError.notConfigured }
        let serial = requestSerial
        let userID = ensureUserID()
        try await SponsorBlockService.shared.submit(
            videoID: source.videoID, cid: source.cid, userID: userID,
            duration: videoDuration, start: start, end: end,
            category: category, actionType: actionType, server: customServer
        )
        // Reflect the contribution immediately.
        guard !Task.isCancelled, requestSerial == serial, requestedSource == source else { return }
        await load(videoID: source.videoID, cid: source.cid)
    }

    func vote(uuid: String, type: Int) async throws {
        let userID = ensureUserID()
        try await SponsorBlockService.shared.vote(uuid: uuid, userID: userID, type: type, server: customServer)
    }

    // MARK: Persistence helpers

    private static func loadActions() -> [SponsorCategory: SponsorAction] {
        guard let raw = UserDefaults.standard.dictionary(forKey: Key.actions) as? [String: String] else { return [:] }
        var result: [SponsorCategory: SponsorAction] = [:]
        for (key, value) in raw {
            if let cat = SponsorCategory(rawValue: key), let act = SponsorAction(rawValue: value) {
                result[cat] = act
            }
        }
        return result
    }

    private func persistActions() {
        let raw = actions.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value.rawValue }
        UserDefaults.standard.set(raw, forKey: Key.actions)
    }
}
