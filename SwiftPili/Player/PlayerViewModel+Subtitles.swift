import AVFoundation
import Foundation
import UIKit

struct PlayerSubtitleTrackOption: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case bilibiliCC
        case localImported
        case systemSpeech
    }

    let id: String
    let title: String
    let kind: Kind
}

extension PlayerViewModel {

    // MARK: - Dual-Track, Local Import & System Speech Facade (backed by PlayerSessionState)

    var secondarySubtitleLan: String? {
        get { session.secondarySubtitleLan }
        set { session.secondarySubtitleLan = newValue }
    }

    var secondarySubtitleText: String? {
        get { session.secondarySubtitleText }
        set { session.secondarySubtitleText = newValue }
    }

    var secondarySubtitleCues: [SubtitleCue] {
        get { session.secondarySubtitleCues }
        set { session.secondarySubtitleCues = newValue }
    }

    var importedSubtitleTracks: [ImportedSubtitleTrack] {
        get { session.importedSubtitleTracks }
        set { session.importedSubtitleTracks = newValue }
    }

    var speechSubtitleStatus: SpeechSubtitleStatus {
        session.speechSubtitleStatus
    }

    var speechSubtitleLocale: SpeechSubtitleLocale {
        session.speechSubtitleLocale
    }

    var speechSubtitleEngineLabel: String? {
        session.speechSubtitleEngineLabel
    }

    var speechSubtitleCanDownloadModel: Bool {
        session.speechSubtitleCanDownloadModel
    }

    var isAutoTranslationEnabled: Bool {
        session.isAutoTranslationEnabled
    }

    var subtitleTranslationTargetLanguage: SubtitleTranslationTargetLanguage {
        session.subtitleTranslationTargetLanguage
    }

    var subtitleTranslationStatus: SubtitleTranslationStatus {
        session.subtitleTranslationService.status
    }

    var subtitleTranslationSessionKey: SubtitleTranslationSessionKey? {
        session.subtitleTranslationService.sessionKey
    }

    var activeTranslationHostID: UUID? {
        session.subtitleTranslationService.activeHostID
    }

    var supportsAutoSubtitleTranslation: Bool {
        #if canImport(Translation)
        true
        #else
        false
        #endif
    }

    var isAutoTranslationActive: Bool {
        session.isAutoTranslationEnabled && activeSubtitleLan != nil && secondarySubtitleLan == nil
    }

    var supportsSystemSpeechSubtitles: Bool {
        backend.supportsSystemSubtitleGeneration
    }

    var isSpeechSubtitleEnabled: Bool {
        PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan)
            || PlayerSubtitleTrackID.isSystemSpeech(secondarySubtitleLan)
    }

    var hasAnyActiveSubtitle: Bool {
        activeSubtitleLan != nil || secondarySubtitleLan != nil
    }

    var allSubtitleTrackOptions: [PlayerSubtitleTrackOption] {
        var options: [PlayerSubtitleTrackOption] = []
        for item in availableSubtitles {
            guard let lan = item.lan, !lan.isEmpty else { continue }
            options.append(
                PlayerSubtitleTrackOption(
                    id: lan,
                    title: item.menuDisplayTitle,
                    kind: .bilibiliCC
                )
            )
        }
        for track in importedSubtitleTracks {
            options.append(
                PlayerSubtitleTrackOption(
                    id: track.id,
                    title: track.displayName,
                    kind: .localImported
                )
            )
        }
        if supportsSystemSpeechSubtitles || isSpeechSubtitleEnabled {
            options.append(
                PlayerSubtitleTrackOption(
                    id: PlayerSubtitleTrackID.systemSpeech,
                    title: String(localized: "Live Speech Subtitles"),
                    kind: .systemSpeech
                )
            )
        }
        return options
    }

    func subtitleDisplayTitle(for trackID: String?) -> String? {
        guard let trackID else { return nil }
        if PlayerSubtitleTrackID.isSystemSpeech(trackID) {
            return String(localized: "Live Speech")
        }
        if let local = importedSubtitleTracks.first(where: { $0.id == trackID }) {
            return local.displayName
        }
        if let item = availableSubtitles.first(where: { $0.lan == trackID }) {
            return item.menuDisplayTitle
        }
        return trackID
    }

    var activeSubtitleSummaryLabel: String? {
        let primary = subtitleDisplayTitle(for: activeSubtitleLan)
        let secondary: String?
        if let explicitSecondary = subtitleDisplayTitle(for: secondarySubtitleLan) {
            secondary = explicitSecondary
        } else if isAutoTranslationActive {
            secondary = String(
                format: String(localized: "Auto %@"),
                session.subtitleTranslationTargetLanguage.shortLabel
            )
        } else {
            secondary = nil
        }
        switch (primary, secondary) {
        case let (p?, s?):
            return "\(p) + \(s)"
        case let (p?, nil):
            return p
        case let (nil, s?):
            return s
        case (nil, nil):
            return nil
        }
    }

    // MARK: - PlayerV2Info Handoff

    func issuePlayerInfoHandoff(
        aid: Int,
        cid: Int,
        ownerLease: PlayerOwnerLease?
    ) -> PlayerInfoHandoffToken? {
        clearPlayerInfoHandoff()
        guard let ownerLease else { return nil }
        return playerInfoHandoffPolicy.issue(
            aid: aid,
            cid: cid,
            owner: ownerLease.owner,
            ownerLeaseGeneration: ownerLease.generation
        )
    }

    func takePlayerInfoHandoff(
        aid: Int,
        cid: Int,
        owner: String?,
        ownerLease: PlayerOwnerLease?
    ) -> PlayerV2Info? {
        guard let pending = pendingPlayerInfo else { return nil }
        guard let owner, let ownerLease else {
            clearPlayerInfoHandoff(matching: currentOwnerLease)
            return nil
        }
        let consumed = playerInfoHandoffPolicy.consume(
            pending.handoff,
            aid: aid,
            cid: cid,
            currentOwner: owner,
            currentOwnerLeaseGeneration: ownerLease.generation,
            isScreenLoad: true
        )
        guard consumed else {
            clearPlayerInfoHandoff(matching: ownerLease)
            return nil
        }
        pendingPlayerInfo = nil
        return pending.info
    }

    func clearPlayerInfoHandoff(matching lease: PlayerOwnerLease? = nil) {
        guard let pending = pendingPlayerInfo else {
            if let lease,
               let active = playerInfoHandoffPolicy.activeToken,
               (active.owner != lease.owner
                   || active.ownerLeaseGeneration != lease.generation) {
                return
            }
            playerInfoHandoffPolicy.invalidate()
            return
        }
        if let lease,
           (pending.handoff.owner != lease.owner
               || pending.handoff.ownerLeaseGeneration != lease.generation) {
            return
        }
        pendingPlayerInfo = nil
        playerInfoHandoffPolicy.invalidate()
    }

    func loadSubtitleList(
        aid: Int,
        cid: Int,
        generation: Int,
        ownerLease: PlayerOwnerLease?,
        preloadedInfo: PlayerV2Info?
    ) async {
        guard generation == loadGeneration,
              ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }
        let info: PlayerV2Info
        if let preloadedInfo {
            info = preloadedInfo
        } else if let fetched = try? await VideoAPI.getPlayerInfo(aid: aid, cid: cid) {
            info = fetched
        } else {
            if SubtitleStylePreferences.shared.autoSpeechMode == .always {
                await applyPersistedSubtitlePreferences(
                    for: [],
                    expectedGeneration: generation,
                    ownerLease: ownerLease
                )
            }
            return
        }
        guard generation == loadGeneration,
              ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }
        let rawSubtitles = info.subtitle?.subtitles ?? []
        let usableSubtitles = rawSubtitles.filter { item in
            let hasLan = !(item.lan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasURL = !(item.subtitleUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasLan && hasURL
        }
        availableSubtitles = usableSubtitles
        noteDanmakuMaskSource(info.dmMask, cid: cid)
        if let ownerLease {
            let frames = PlayerAmbientStoryboardFrame.admitted(info.viewPoints)
            setAmbientStoryboard(
                frames,
                ownerLease: ownerLease,
                loadGeneration: generation
            )
        }
        if !usableSubtitles.isEmpty {
            let summary = usableSubtitles.map { item in
                "\(item.menuDisplayTitle) [\(item.lan ?? "?")]"
            }.joined(separator: ", ")
            PlayerLog.log("[Player] Bilibili CC subtitles (\(usableSubtitles.count)): \(summary)")
        } else if !rawSubtitles.isEmpty {
            PlayerLog.log("[Player] Bilibili CC subtitles returned \(rawSubtitles.count) entries with empty URLs")
        }
        await applyPersistedSubtitlePreferences(
            for: usableSubtitles,
            expectedGeneration: generation,
            ownerLease: ownerLease
        )
    }

    func applyPersistedSubtitlePreferences(
        for list: [PlayerV2Info.SubtitleBox.SubtitleItem],
        expectedGeneration: Int,
        ownerLease: PlayerOwnerLease? = nil
    ) async {
        guard expectedGeneration == loadGeneration,
              ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }

        let prefs = SubtitleStylePreferences.shared
        session.isAutoTranslationEnabled = prefs.autoTranslateEnabled
        session.speechSubtitleLocale = prefs.speechLocale
        session.subtitleTranslationTargetLanguage = prefs.translationTargetLanguage

        guard activeSubtitleLan == nil else {
            refreshAutoSubtitleTranslation()
            return
        }

        if prefs.autoSpeechMode == .always, supportsSystemSpeechSubtitles {
            applySystemSpeechSubtitlesEnabled(true, persistPreference: false)
            refreshAutoSubtitleTranslation()
            return
        }

        let resolved = prefs.resolveInitialCloudTracks(from: list)
        if let primaryLan = resolved.primaryLan,
           let primaryItem = list.first(where: { $0.lan == primaryLan }) {
            let secondaryLan = resolved.secondaryLan.flatMap { $0 != primaryLan ? $0 : nil }
            await applyCloudPrimarySubtitle(
                primaryItem,
                persistPreference: false,
                suppressTranslationReconcile: secondaryLan != nil
            )
            guard expectedGeneration == loadGeneration,
                  ownerLease.map({ isCurrentOwner($0) }) ?? true else { return }
            if let secondaryLan, activeSubtitleLan == primaryLan {
                await applySecondarySubtitleTrack(id: secondaryLan, persistPreference: false)
            }
            refreshAutoSubtitleTranslation()
            return
        }

        if prefs.autoSpeechMode == .whenNoCloudSubtitles,
           list.isEmpty,
           supportsSystemSpeechSubtitles {
            applySystemSpeechSubtitlesEnabled(true, persistPreference: false)
            refreshAutoSubtitleTranslation()
            return
        }

        refreshAutoSubtitleTranslation()
    }

    func refreshAutoSubtitleTranslation() {
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
    }

    // MARK: - Primary & Secondary Subtitle Track Selection

    func selectSubtitle(_ item: PlayerV2Info.SubtitleBox.SubtitleItem?) async {
        guard let item else {
            turnOffAllSubtitles()
            return
        }
        guard item.subtitleUrl != nil else {
            clearPrimarySubtitleState()
            return
        }
        await applyCloudPrimarySubtitle(item, persistPreference: true)
    }

    private func applyCloudPrimarySubtitle(
        _ item: PlayerV2Info.SubtitleBox.SubtitleItem,
        persistPreference: Bool,
        suppressTranslationReconcile: Bool = false
    ) async {
        subtitleSelectionGeneration &+= 1
        let selectionGen = subtitleSelectionGeneration
        let streamGen = loadGeneration
        let lease = currentOwnerLease
        guard let urlString = item.subtitleUrl else {
            clearPrimarySubtitleState()
            return
        }
        if persistPreference, let lan = item.lan, !lan.isEmpty {
            let prefs = SubtitleStylePreferences.shared
            prefs.autoEnableCloudSubtitles = true
            if let inferred = SubtitlePreferredLanguage.inferred(from: lan) {
                prefs.preferredPrimaryLanguage = inferred
            }
            if prefs.autoSpeechMode == .always {
                prefs.autoSpeechMode = .whenNoCloudSubtitles
            }
        }
        if secondarySubtitleLan == item.lan {
            clearSecondarySubtitleState()
            if persistPreference {
                SubtitleStylePreferences.shared.preferredSecondaryLanguage = .none
            }
        }
        PlayerLog.log("[Player] selectSubtitle(\(item.lan ?? "?")): playing=\(isPlaying) t=\(String(format: "%.1f", mediaTime))")
        activeSubtitleLan = item.lan
        subtitleCues = []
        session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
        subtitleText = nil
        reconcileSystemSpeechGeneratorState()
        if !suppressTranslationReconcile {
            reconcileSubtitleTranslationState()
        }
        do {
            let loadedCues = try await Self.fetchBilibiliSubtitleCues(from: urlString)
            guard !Task.isCancelled,
                  subtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            subtitleCues = loadedCues
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: loadedCues)
            if !suppressTranslationReconcile {
                reconcileSubtitleTranslationState()
            }
            updateSubtitle(at: mediaTime)
            PlayerLog.log("[Player] subtitle \(item.lan ?? "?") loaded: \(subtitleCues.count) cues")
        } catch {
            guard subtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            PlayerLog.log("[Player] subtitle load failed: \(error)")
            activeSubtitleLan = nil
            subtitleCues = []
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
            subtitleText = nil
            if !suppressTranslationReconcile {
                reconcileSubtitleTranslationState()
            }
            updateSubtitle(at: mediaTime)
        }
    }

    func selectPrimarySubtitleTrack(id: String?) async {
        guard let id else {
            let previousPrimary = activeSubtitleLan
            clearPrimarySubtitleState()
            let prefs = SubtitleStylePreferences.shared
            if PlayerSubtitleTrackID.isSystemSpeech(previousPrimary), !isSpeechSubtitleEnabled {
                prefs.autoSpeechMode = .off
            } else if previousPrimary != nil, !PlayerSubtitleTrackID.isLocal(previousPrimary) {
                prefs.autoEnableCloudSubtitles = false
            }
            if !hasAnyActiveSubtitle {
                prefs.autoEnableCloudSubtitles = false
                prefs.autoSpeechMode = .off
            }
            return
        }
        if secondarySubtitleLan == id {
            clearSecondarySubtitleState()
            SubtitleStylePreferences.shared.preferredSecondaryLanguage = .none
        }
        if PlayerSubtitleTrackID.isSystemSpeech(id) {
            guard supportsSystemSpeechSubtitles else {
                session.speechSubtitleStatus = .unsupportedBackend
                return
            }
            let prefs = SubtitleStylePreferences.shared
            if prefs.autoSpeechMode == .off {
                prefs.autoSpeechMode = availableSubtitles.isEmpty ? .whenNoCloudSubtitles : .always
            } else if prefs.autoSpeechMode == .whenNoCloudSubtitles, !availableSubtitles.isEmpty {
                prefs.autoSpeechMode = .always
            }
            subtitleSelectionGeneration &+= 1
            activeSubtitleLan = PlayerSubtitleTrackID.systemSpeech
            subtitleCues = []
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
            subtitleText = nil
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }
        if let local = importedSubtitleTracks.first(where: { $0.id == id }) {
            subtitleSelectionGeneration &+= 1
            activeSubtitleLan = local.id
            subtitleCues = local.cues
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: local.cues)
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }
        if let item = availableSubtitles.first(where: { $0.lan == id }) {
            await applyCloudPrimarySubtitle(item, persistPreference: true)
        }
    }

    func selectSecondarySubtitleTrack(id: String?) async {
        await applySecondarySubtitleTrack(id: id, persistPreference: true)
    }

    private func applySecondarySubtitleTrack(
        id: String?,
        persistPreference: Bool
    ) async {
        session.secondarySubtitleSelectionGeneration &+= 1
        let selectionGen = session.secondarySubtitleSelectionGeneration
        let streamGen = loadGeneration
        let lease = currentOwnerLease

        guard let id, id != activeSubtitleLan else {
            let wasSpeech = PlayerSubtitleTrackID.isSystemSpeech(secondarySubtitleLan)
            clearSecondarySubtitleState()
            if persistPreference {
                let prefs = SubtitleStylePreferences.shared
                prefs.preferredSecondaryLanguage = .none
                if wasSpeech, !isSpeechSubtitleEnabled {
                    prefs.autoSpeechMode = .off
                }
            }
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }

        if persistPreference {
            // Selecting an explicit manual secondary track takes over the secondary bilingual line.
            session.isAutoTranslationEnabled = false
            SubtitleStylePreferences.shared.autoTranslateEnabled = false
        }

        if PlayerSubtitleTrackID.isSystemSpeech(id) {
            guard supportsSystemSpeechSubtitles else {
                session.speechSubtitleStatus = .unsupportedBackend
                return
            }
            if persistPreference, SubtitleStylePreferences.shared.autoSpeechMode == .off {
                SubtitleStylePreferences.shared.autoSpeechMode =
                    availableSubtitles.isEmpty ? .whenNoCloudSubtitles : .always
            }
            secondarySubtitleLan = PlayerSubtitleTrackID.systemSpeech
            secondarySubtitleCues = []
            secondarySubtitleText = nil
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }

        if let local = importedSubtitleTracks.first(where: { $0.id == id }) {
            secondarySubtitleLan = local.id
            secondarySubtitleCues = local.cues
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }

        guard let item = availableSubtitles.first(where: { $0.lan == id }),
              let urlString = item.subtitleUrl else {
            clearSecondarySubtitleState()
            if persistPreference {
                SubtitleStylePreferences.shared.preferredSecondaryLanguage = .none
            }
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
            return
        }

        if persistPreference {
            SubtitleStylePreferences.shared.preferredSecondaryLanguage =
                SubtitlePreferredSecondaryLanguage.inferred(from: item.lan)
        }

        secondarySubtitleLan = item.lan
        secondarySubtitleCues = []
        secondarySubtitleText = nil
        reconcileSystemSpeechGeneratorState()
        reconcileSubtitleTranslationState()

        do {
            let loadedCues = try await Self.fetchBilibiliSubtitleCues(from: urlString)
            guard !Task.isCancelled,
                  session.secondarySubtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            secondarySubtitleCues = loadedCues
            updateSubtitle(at: mediaTime)
            PlayerLog.log("[Player] secondary subtitle \(item.lan ?? "?") loaded: \(loadedCues.count) cues")
        } catch {
            guard session.secondarySubtitleSelectionGeneration == selectionGen,
                  loadGeneration == streamGen,
                  lease == nil || currentOwnerLease == lease else {
                return
            }
            PlayerLog.log("[Player] secondary subtitle load failed: \(error)")
            clearSecondarySubtitleState()
            reconcileSubtitleTranslationState()
        }
    }

    func togglePrimarySubtitleTrack(id: String) async {
        if activeSubtitleLan == id {
            await selectPrimarySubtitleTrack(id: nil)
        } else {
            await selectPrimarySubtitleTrack(id: id)
        }
    }

    func toggleSecondarySubtitleTrack(id: String) async {
        if secondarySubtitleLan == id {
            await selectSecondarySubtitleTrack(id: nil)
            return
        }
        if activeSubtitleLan == id {
            clearPrimarySubtitleState()
        }
        await selectSecondarySubtitleTrack(id: id)
    }

    func turnOffAllSubtitles() {
        let prefs = SubtitleStylePreferences.shared
        prefs.autoEnableCloudSubtitles = false
        prefs.preferredSecondaryLanguage = .none
        prefs.autoTranslateEnabled = false
        prefs.autoSpeechMode = .off
        clearAllSubtitleTracksWithoutPersisting()
    }

    private func clearPrimarySubtitleState() {
        subtitleSelectionGeneration &+= 1
        activeSubtitleLan = nil
        subtitleCues = []
        session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
        subtitleText = nil
        reconcileSystemSpeechGeneratorState()
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
    }

    private func clearAllSubtitleTracksWithoutPersisting() {
        subtitleSelectionGeneration &+= 1
        activeSubtitleLan = nil
        subtitleCues = []
        session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
        subtitleText = nil
        session.isAutoTranslationEnabled = false
        clearSecondarySubtitleState()
        reconcileSystemSpeechGeneratorState()
        reconcileSubtitleTranslationState()
    }

    // MARK: - On-Device Bilingual Auto-Translation

    func setAutoSubtitleTranslationEnabled(_ enabled: Bool) {
        SubtitleStylePreferences.shared.autoTranslateEnabled = enabled
        if enabled, secondarySubtitleLan != nil {
            clearSecondarySubtitleState()
            SubtitleStylePreferences.shared.preferredSecondaryLanguage = .none
            reconcileSystemSpeechGeneratorState()
        }
        session.isAutoTranslationEnabled = enabled
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
    }

    func setSubtitleTranslationTargetLanguage(_ language: SubtitleTranslationTargetLanguage) {
        SubtitleStylePreferences.shared.translationTargetLanguage = language
        guard session.subtitleTranslationTargetLanguage != language else { return }
        session.subtitleTranslationTargetLanguage = language
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
    }

    func retrySubtitleTranslation() {
        session.subtitleTranslationService.retry()
    }

    func registerSubtitleTranslationHost(_ id: UUID, priority: Int) {
        session.subtitleTranslationService.registerHost(id, priority: priority)
    }

    func unregisterSubtitleTranslationHost(_ id: UUID) {
        session.subtitleTranslationService.unregisterHost(id)
    }

    private func reconcileSubtitleTranslationState() {
        let service = session.subtitleTranslationService
        if service.onTranslationsUpdated == nil {
            service.onTranslationsUpdated = { [weak self] in
                guard let self else { return }
                self.updateSubtitle(at: self.mediaTime)
            }
        }

        let explicitSourceHint: String?
        if PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan) {
            explicitSourceHint = SubtitleSourceLanguageResolver.sourceIdentifier(
                for: session.speechSubtitleLocale
            )
        } else if let lan = activeSubtitleLan,
                  let item = availableSubtitles.first(where: { $0.lan == lan }) {
            explicitSourceHint = SubtitleSourceLanguageResolver.sourceIdentifier(
                forBilibiliLan: item.lan
            )
        } else {
            explicitSourceHint = nil
        }

        service.configure(
            enabled: session.isAutoTranslationEnabled && secondarySubtitleLan == nil,
            targetLanguage: session.subtitleTranslationTargetLanguage,
            primaryTrackID: activeSubtitleLan,
            primaryCues: PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan) ? [] : subtitleCues,
            explicitSourceHint: explicitSourceHint,
            focusTime: mediaTime
        )
    }

    // MARK: - Local .srt / .vtt Import

    @discardableResult
    func importLocalSubtitle(from url: URL) throws -> ImportedSubtitleTrack {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        return try importLocalSubtitle(data: data, fileName: url.lastPathComponent)
    }

    @discardableResult
    func importLocalSubtitle(
        data: Data,
        fileName: String,
        assignToSecondaryIfPrimaryActive: Bool = false
    ) throws -> ImportedSubtitleTrack {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let cues = try SubtitleParser.parse(data: data, fileExtension: ext)
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let cleanTitle = stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fileName
            : stem
        let track = ImportedSubtitleTrack(
            id: PlayerSubtitleTrackID.makeLocalID(),
            displayName: cleanTitle,
            fileName: fileName,
            cues: cues
        )
        importedSubtitleTracks.append(track)

        if assignToSecondaryIfPrimaryActive, activeSubtitleLan != nil, secondarySubtitleLan == nil {
            session.isAutoTranslationEnabled = false
            session.secondarySubtitleSelectionGeneration &+= 1
            secondarySubtitleLan = track.id
            secondarySubtitleCues = track.cues
        } else {
            subtitleSelectionGeneration &+= 1
            activeSubtitleLan = track.id
            subtitleCues = track.cues
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: track.cues)
        }

        reconcileSystemSpeechGeneratorState()
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
        PlayerLog.log("[Player] imported local subtitle \(fileName): \(cues.count) cues")
        return track
    }

    func removeImportedSubtitleTrack(id: String) {
        importedSubtitleTracks.removeAll { $0.id == id }
        if activeSubtitleLan == id {
            subtitleSelectionGeneration &+= 1
            activeSubtitleLan = nil
            subtitleCues = []
            session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
            subtitleText = nil
        }
        if secondarySubtitleLan == id {
            clearSecondarySubtitleState()
        }
        reconcileSystemSpeechGeneratorState()
        reconcileSubtitleTranslationState()
        updateSubtitle(at: mediaTime)
    }

    // MARK: - System On-Device Speech Subtitles

    func setSystemSpeechSubtitlesEnabled(_ enabled: Bool) {
        applySystemSpeechSubtitlesEnabled(enabled, persistPreference: true)
    }

    private func applySystemSpeechSubtitlesEnabled(
        _ enabled: Bool,
        persistPreference: Bool
    ) {
        if enabled {
            guard supportsSystemSpeechSubtitles else {
                session.speechSubtitleStatus = .unsupportedBackend
                return
            }
            if persistPreference, SubtitleStylePreferences.shared.autoSpeechMode == .off {
                SubtitleStylePreferences.shared.autoSpeechMode =
                    availableSubtitles.isEmpty ? .whenNoCloudSubtitles : .always
            }
            if !isSpeechSubtitleEnabled {
                if activeSubtitleLan == nil {
                    subtitleSelectionGeneration &+= 1
                    activeSubtitleLan = PlayerSubtitleTrackID.systemSpeech
                    subtitleCues = []
                    session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
                    subtitleText = nil
                } else if secondarySubtitleLan == nil && !session.isAutoTranslationEnabled {
                    session.secondarySubtitleSelectionGeneration &+= 1
                    secondarySubtitleLan = PlayerSubtitleTrackID.systemSpeech
                    secondarySubtitleCues = []
                    secondarySubtitleText = nil
                } else {
                    subtitleSelectionGeneration &+= 1
                    activeSubtitleLan = PlayerSubtitleTrackID.systemSpeech
                    subtitleCues = []
                    session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
                    subtitleText = nil
                }
            }
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
        } else {
            if persistPreference {
                SubtitleStylePreferences.shared.autoSpeechMode = .off
            }
            if PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan) {
                subtitleSelectionGeneration &+= 1
                activeSubtitleLan = nil
                subtitleCues = []
                session.primarySubtitleCueIndex = SubtitleCueIndex(cues: [])
                subtitleText = nil
            }
            if PlayerSubtitleTrackID.isSystemSpeech(secondarySubtitleLan) {
                clearSecondarySubtitleState()
            }
            reconcileSystemSpeechGeneratorState()
            reconcileSubtitleTranslationState()
            updateSubtitle(at: mediaTime)
        }
    }

    func setSpeechSubtitleLocale(_ locale: SpeechSubtitleLocale) {
        SubtitleStylePreferences.shared.speechLocale = locale
        guard session.speechSubtitleLocale != locale else { return }
        session.speechSubtitleLocale = locale
        if isSpeechSubtitleEnabled {
            startOrRestartSystemSpeechGenerator()
        }
        reconcileSubtitleTranslationState()
    }

    @discardableResult
    func downloadSpeechAnalyzerModel() async -> Bool {
        let generator = ensureSystemSpeechGenerator()
        return await generator.downloadSpeechAnalyzerModel(for: session.speechSubtitleLocale)
    }

    private func ensureSystemSpeechGenerator() -> SystemSpeechSubtitleGenerator {
        if let existing = session.speechSubtitleGenerator {
            return existing
        }
        let generator = SystemSpeechSubtitleGenerator()
        generator.onStatusChanged = { [weak self] status, engineLabel, canDownloadModel in
            guard let self else { return }
            self.session.speechSubtitleStatus = status
            self.session.speechSubtitleEngineLabel = engineLabel
            self.session.speechSubtitleCanDownloadModel = canDownloadModel
        }
        generator.onSubtitlesUpdated = { [weak self] in
            guard let self else { return }
            self.updateSubtitle(at: self.pendingSeekTarget ?? self.mediaTime)
        }
        session.speechSubtitleGenerator = generator
        return generator
    }

    func handleSpeechSubtitlesSeek(to time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        session.speechSubtitleGenerator?.handleSeek(to: time)
    }

    private func reconcileSystemSpeechGeneratorState() {
        if isSpeechSubtitleEnabled {
            guard supportsSystemSpeechSubtitles else {
                session.speechSubtitleStatus = .unsupportedBackend
                return
            }
            if !session.speechSubtitleStatus.isRunning {
                startOrRestartSystemSpeechGenerator()
            } else if let tap = session.speechSubtitleTap {
                backend.setSubtitlePCMTap(tap)
            }
        } else {
            session.speechSubtitleGenerator?.stop()
            session.speechSubtitleTap?.deactivate()
            backend.setSubtitlePCMTap(nil)
            session.speechSubtitleStatus = .idle
            session.speechSubtitleEngineLabel = nil
            session.speechSubtitleCanDownloadModel = false
        }
    }

    private func startOrRestartSystemSpeechGenerator() {
        guard supportsSystemSpeechSubtitles else {
            session.speechSubtitleStatus = .unsupportedBackend
            return
        }
        let tap: AudioPCMSubtitleTap
        if let existing = session.speechSubtitleTap {
            tap = existing
        } else {
            let created = AudioPCMSubtitleTap()
            session.speechSubtitleTap = created
            tap = created
        }
        session.onDetachSpeechSubtitleTap = { [weak self] in
            self?.backend.setSubtitlePCMTap(nil)
        }
        backend.setSubtitlePCMTap(tap)
        let generator = ensureSystemSpeechGenerator()
        let initialTime: TimeInterval?
        if let target = pendingSeekTarget, target.isFinite, target >= 0 {
            initialTime = target
        } else if mediaTime.isFinite, mediaTime > 0 {
            initialTime = mediaTime
        } else if let resume = resumeAtTime, resume.isFinite, resume > 0 {
            initialTime = resume
        } else if mode != .live, mediaTime.isFinite, mediaTime >= 0 {
            initialTime = mediaTime
        } else {
            initialTime = nil
        }
        generator.start(
            tap: tap,
            locale: session.speechSubtitleLocale,
            initialMediaTime: initialTime
        )
    }

    private func clearSecondarySubtitleState() {
        session.secondarySubtitleSelectionGeneration &+= 1
        secondarySubtitleLan = nil
        secondarySubtitleCues = []
        secondarySubtitleText = nil
    }

    // MARK: - Per-Tick Dual-Track Cue Lookup

    func updateSubtitle(at time: TimeInterval) {
        let primaryText: String?
        if PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan) {
            primaryText = session.speechSubtitleGenerator?.activeText(at: time)
        } else if !subtitleCues.isEmpty {
            primaryText = lookupPrimaryCueText(at: time)
        } else {
            primaryText = nil
        }

        if primaryText != subtitleText {
            subtitleText = primaryText
        }

        let secondaryText: String?
        if PlayerSubtitleTrackID.isSystemSpeech(secondarySubtitleLan) {
            secondaryText = session.speechSubtitleGenerator?.activeText(at: time)
        } else if !session.secondarySubtitleCues.isEmpty {
            secondaryText = session.secondarySubtitleCueIndex.activeText(at: time)
        } else if isAutoTranslationActive, let primaryText {
            let target = session.subtitleTranslationTargetLanguage
            if let translated = session.subtitleTranslationService.cachedTranslation(
                for: primaryText,
                targetLanguage: target
            ) {
                secondaryText = translated
            } else {
                secondaryText = nil
                if PlayerSubtitleTrackID.isSystemSpeech(activeSubtitleLan) {
                    session.subtitleTranslationService.enqueueLiveText(primaryText)
                } else {
                    session.subtitleTranslationService.prioritize(focusTime: time)
                }
            }
        } else {
            secondaryText = nil
        }

        if secondaryText != session.secondarySubtitleText {
            session.secondarySubtitleText = secondaryText
        }
    }

    private func lookupPrimaryCueText(at time: TimeInterval) -> String? {
        switch subtitleCueTimeline?.search(at: time, cues: subtitleCues) {
        case .match(let content):
            return content
        case .noMatch:
            return nil
        case .unavailable, nil:
            let index = session.primarySubtitleCueIndex
            if index.cues.count == subtitleCues.count,
               let firstCached = index.cues.first, let firstCurrent = subtitleCues.first,
               let lastCached = index.cues.last, let lastCurrent = subtitleCues.last,
               firstCached.from == firstCurrent.from, firstCached.content == firstCurrent.content,
               lastCached.to == lastCurrent.to, lastCached.content == lastCurrent.content {
                return index.activeText(at: time)
            }
            return SubtitleParser.activeText(at: time, in: subtitleCues)
        }
    }

    nonisolated static func normalizedBilibiliSubtitleURLString(_ rawURLString: String) -> String {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if trimmed.lowercased().hasPrefix("http://") {
            return "https://" + trimmed.dropFirst("http://".count)
        }
        return trimmed
    }

    private nonisolated static func fetchBilibiliSubtitleCues(
        from rawURLString: String
    ) async throws -> [SubtitleCue] {
        let urlString = normalizedBilibiliSubtitleURLString(rawURLString)
        guard let url = URL(string: urlString) else {
            throw SubtitleParseError.emptyOrUnsupportedFormat
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if url.scheme?.lowercased() != "file" {
            request.setValue(BiliAPIClient.defaultReferer, forHTTPHeaderField: "Referer")
            request.setValue(BiliAPIClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        struct SubtitleFile: Decodable {
            struct Cue: Decodable {
                let from: Double?
                let to: Double?
                let content: String?
            }

            let body: [Cue]?
        }
        let parsed = try JSONDecoder().decode(SubtitleFile.self, from: data)
        return (parsed.body ?? []).compactMap { cue in
            guard let from = cue.from, let to = cue.to, let content = cue.content else { return nil }
            return SubtitleCue(from: from, to: to, content: content)
        }
    }
}
