import AVFoundation
import CoreFoundation
import Foundation
import Testing
@testable import SwiftPili

// MARK: - Track 4: SRT/VTT Parser

@Suite("Track 4: SubtitleParser (SRT, VTT & Encodings)")
struct Track4SubtitleParserTests {
    @Test("Parses SRT with comma ms, multi-line cues, HTML & ASS tag stripping, and entities")
    func srtParsingAndTagStripping() throws {
        let srt = """
        1
        00:00:01,250 --> 00:00:03,750
        {\\an8}<i>Hello &amp; welcome</i>
        <b>Second line</b> with 1 < 2

        2
        00:01:02,000 --> 00:01:05,500
        {\\pos(100,200)}<font color="#ffcc00">Styled text</font>
        """
        let cues = try SubtitleParser.parse(data: Data(srt.utf8), fileExtension: "srt")
        #expect(cues.count == 2)

        #expect(abs(cues[0].from - 1.25) < 1e-6)
        #expect(abs(cues[0].to - 3.75) < 1e-6)
        #expect(cues[0].content == "Hello & welcome\nSecond line with 1 < 2")

        #expect(abs(cues[1].from - 62.0) < 1e-6)
        #expect(abs(cues[1].to - 65.5) < 1e-6)
        #expect(cues[1].content == "Styled text")
    }

    @Test("Parses WebVTT with WEBVTT header, NOTE/STYLE blocks, cue settings, and MM:SS.mmm / HH:MM:SS.mmm")
    func webVTTParsing() throws {
        let vtt = """
        WEBVTT - Demo Captions

        NOTE
        This comment should be ignored completely.

        STYLE
        ::cue { color: white; }

        intro-cue
        00:02.500 --> 00:05.000 align:start position:10% line:85%
        <v Narrator>Short timestamp cue

        01:02:03.400 --> 01:02:06.900 line:90%
        <c.yellow>Long hour cue</c> with <01:02:04.000>inline timing
        """
        let cues = try SubtitleParser.parse(data: Data(vtt.utf8), fileExtension: "vtt")
        #expect(cues.count == 2)

        #expect(abs(cues[0].from - 2.5) < 1e-6)
        #expect(abs(cues[0].to - 5.0) < 1e-6)
        #expect(cues[0].content == "Short timestamp cue")

        #expect(abs(cues[1].from - 3723.4) < 1e-6)
        #expect(abs(cues[1].to - 3726.9) < 1e-6)
        #expect(cues[1].content == "Long hour cue with inline timing")
    }

    @Test("Auto-detects UTF-8 BOM, UTF-16 LE BOM, and GB18030 encoded Chinese SRT files")
    func encodingAutoDetection() throws {
        let chineseSRT = """
        1
        00:00:00,500 --> 00:00:02,500
        你好，哔哩哔哩！
        """

        // 1. UTF-8 with BOM
        var utf8BOMData = Data([0xEF, 0xBB, 0xBF])
        utf8BOMData.append(Data(chineseSRT.utf8))
        let utf8Cues = try SubtitleParser.parse(data: utf8BOMData, fileExtension: "srt")
        #expect(utf8Cues.count == 1)
        #expect(utf8Cues[0].content == "你好，哔哩哔哩！")

        // 2. GB18030 encoded Chinese bytes (invalid UTF-8)
        let cfGB = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfGB))
        let gbData = try #require(chineseSRT.data(using: gbEncoding))
        #expect(String(data: gbData, encoding: .utf8) == nil)
        let gbCues = try SubtitleParser.parse(data: gbData, fileExtension: "srt")
        #expect(gbCues.count == 1)
        #expect(gbCues[0].content == "你好，哔哩哔哩！")

        // 3. UTF-16 LE with BOM
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append(try #require(chineseSRT.data(using: .utf16LittleEndian)))
        let utf16Cues = try SubtitleParser.parse(data: utf16Data, fileExtension: "srt")
        #expect(utf16Cues.count == 1)
        #expect(utf16Cues[0].content == "你好，哔哩哔哩！")
    }

    @Test("Throws emptyOrUnsupportedFormat on malformed input")
    func malformedSubtitleRejected() {
        #expect(throws: SubtitleParseError.emptyOrUnsupportedFormat) {
            try SubtitleParser.parse(data: Data("just plain text without timestamps".utf8))
        }
    }
}

// MARK: - Track 4: Style Preferences Persistence

@Suite("Track 4: SubtitleStylePreferences Persistence")
@MainActor
struct Track4SubtitleStylePreferencesTests {
    @Test("Persists font scale, background style, clamped opacity, clamped bottom offset, and speech locale")
    func stylePreferencesRoundTripAndClamping() throws {
        let suiteName = "com.swiftpili.tests.subtitleStyle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let writer = SubtitleStylePreferences(defaults: defaults)
        #expect(writer.fontSizeScale == .standard)
        #expect(writer.backgroundStyle == .translucentBox)
        #expect(abs(writer.backgroundOpacity - SubtitleStylePreferences.defaultBackgroundOpacity) < 1e-9)
        #expect(writer.bottomOffset == 0)
        #expect(writer.speechLocale == .auto)

        writer.fontSizeScale = .extraLarge
        writer.backgroundStyle = .noneWithStroke
        writer.backgroundOpacity = 0.85
        writer.bottomOffset = 64
        writer.speechLocale = .japanese
        writer.translationTargetLanguage = .english

        // Reload in a brand-new instance backed by the same UserDefaults suite.
        let reader = SubtitleStylePreferences(defaults: defaults)
        #expect(reader.fontSizeScale == .extraLarge)
        #expect(reader.fontSizeScale.multiplier == 1.4)
        #expect(reader.backgroundStyle == .noneWithStroke)
        #expect(abs(reader.backgroundOpacity - 0.85) < 1e-9)
        #expect(reader.bottomOffset == 64)
        #expect(reader.speechLocale == .japanese)
        #expect(reader.translationTargetLanguage == .english)

        // Verify clamping bounds.
        reader.backgroundOpacity = 0.01
        #expect(abs(reader.backgroundOpacity - SubtitleStylePreferences.minBackgroundOpacity) < 1e-9)
        reader.backgroundOpacity = 2.5
        #expect(abs(reader.backgroundOpacity - SubtitleStylePreferences.maxBackgroundOpacity) < 1e-9)

        reader.bottomOffset = -20
        #expect(reader.bottomOffset == SubtitleStylePreferences.minBottomOffset)
        reader.bottomOffset = 250
        #expect(reader.bottomOffset == SubtitleStylePreferences.maxBottomOffset)

        // Reset restores appearance defaults cleanly while persisting.
        reader.resetAppearanceToDefaults()
        let afterReset = SubtitleStylePreferences(defaults: defaults)
        #expect(afterReset.fontSizeScale == .standard)
        #expect(afterReset.backgroundStyle == .translucentBox)
        #expect(abs(afterReset.backgroundOpacity - SubtitleStylePreferences.defaultBackgroundOpacity) < 1e-9)
        #expect(afterReset.bottomOffset == 0)
        #expect(afterReset.speechLocale == .japanese)
    }

    @Test("Persists cross-video subtitle behavior defaults across UserDefaults reloads")
    func crossVideoSubtitleBehaviorPersistence() throws {
        let suiteName = "com.swiftpili.tests.subtitleBehavior.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let writer = SubtitleStylePreferences(defaults: defaults)
        #expect(writer.autoEnableCloudSubtitles == false)
        #expect(writer.preferredPrimaryLanguage == .chineseSimplified)
        #expect(writer.preferredSecondaryLanguage == .none)
        #expect(writer.autoTranslateEnabled == false)
        #expect(writer.autoSpeechMode == .off)
        #expect(writer.hasAutoSubtitleBehaviorEnabled == false)

        writer.autoEnableCloudSubtitles = true
        writer.preferredPrimaryLanguage = .japanese
        writer.preferredSecondaryLanguage = .chineseTraditional
        writer.autoTranslateEnabled = true
        writer.autoSpeechMode = .whenNoCloudSubtitles
        #expect(writer.hasAutoSubtitleBehaviorEnabled == true)

        let reader = SubtitleStylePreferences(defaults: defaults)
        #expect(reader.autoEnableCloudSubtitles == true)
        #expect(reader.preferredPrimaryLanguage == .japanese)
        #expect(reader.preferredSecondaryLanguage == .chineseTraditional)
        #expect(reader.autoTranslateEnabled == true)
        #expect(reader.autoSpeechMode == .whenNoCloudSubtitles)

        // Resetting appearance must not clear cross-video subtitle behavior preferences.
        reader.resetAppearanceToDefaults()
        let afterReset = SubtitleStylePreferences(defaults: defaults)
        #expect(afterReset.autoEnableCloudSubtitles == true)
        #expect(afterReset.preferredPrimaryLanguage == .japanese)
        #expect(afterReset.preferredSecondaryLanguage == .chineseTraditional)
        #expect(afterReset.autoTranslateEnabled == true)
        #expect(afterReset.autoSpeechMode == .whenNoCloudSubtitles)

        // Language matcher & inference coverage.
        #expect(SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh-CN"))
        #expect(SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh-Hans"))
        #expect(SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "ai-zh"))
        #expect(SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh"))
        #expect(!SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh-Hant"))
        #expect(!SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh-TW"))
        #expect(!SubtitlePreferredLanguage.chineseSimplified.matches(bilibiliLan: "zh-HK"))
        #expect(SubtitlePreferredLanguage.chineseTraditional.matches(bilibiliLan: "zh-Hant"))
        #expect(SubtitlePreferredLanguage.chineseTraditional.matches(bilibiliLan: "zh-TW"))
        #expect(SubtitlePreferredLanguage.chineseTraditional.matches(bilibiliLan: "zh-HK"))
        #expect(SubtitlePreferredLanguage.english.matches(bilibiliLan: "en"))
        #expect(SubtitlePreferredLanguage.english.matches(bilibiliLan: "en-US"))
        #expect(SubtitlePreferredLanguage.english.matches(bilibiliLan: "ai-en"))
        #expect(SubtitlePreferredLanguage.japanese.matches(bilibiliLan: "ja"))
        #expect(SubtitlePreferredLanguage.japanese.matches(bilibiliLan: "ja-JP"))
        #expect(SubtitlePreferredLanguage.japanese.matches(bilibiliLan: "ai-ja"))
        #expect(SubtitlePreferredLanguage.japanese.matches(bilibiliLan: "jp"))
        #expect(SubtitlePreferredLanguage.firstAvailable.matches(bilibiliLan: "ko"))
        #expect(!SubtitlePreferredLanguage.firstAvailable.matches(bilibiliLan: "  "))

        #expect(SubtitlePreferredLanguage.inferred(from: "ai-zh") == .chineseSimplified)
        #expect(SubtitlePreferredLanguage.inferred(from: "zh-TW") == .chineseTraditional)
        #expect(SubtitlePreferredLanguage.inferred(from: "en-GB") == .english)
        #expect(SubtitlePreferredLanguage.inferred(from: "ai-ja") == .japanese)
        #expect(SubtitlePreferredLanguage.inferred(from: "ko") == nil)
        #expect(SubtitlePreferredSecondaryLanguage.inferred(from: "en-US") == .english)
        #expect(SubtitlePreferredSecondaryLanguage.inferred(from: nil) == .none)
    }

    @Test("resolveInitialCloudTracks prefers non-AI, falls back to AI and first available, and resolves distinct secondary")
    func resolveInitialCloudTracksResolution() throws {
        let suiteName = "com.swiftpili.tests.subtitleResolve.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = SubtitleStylePreferences(defaults: defaults)
        let aiZh = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "ai-zh", lanDoc: "中文（自动生成）", subtitleUrl: "https://example.com/ai-zh.json", aiType: 1
        )
        let manualZh = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "zh-CN", lanDoc: "中文", subtitleUrl: "https://example.com/zh.json", aiType: 0
        )
        let aiEn = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "ai-en", lanDoc: "English", subtitleUrl: "https://example.com/ai-en.json", aiType: 1
        )
        let manualEn = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "en-US", lanDoc: "English (US)", subtitleUrl: "https://example.com/en.json", aiType: 0
        )
        let blankLan = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "   ", lanDoc: "Invalid", subtitleUrl: "https://example.com/invalid.json", aiType: 0
        )

        // 1. Disabled returns (nil, nil) even when tracks exist.
        prefs.autoEnableCloudSubtitles = false
        let disabled = prefs.resolveInitialCloudTracks(from: [manualZh, manualEn])
        #expect(disabled.primaryLan == nil)
        #expect(disabled.secondaryLan == nil)

        // 2. Enabled prefers non-AI matching primary & non-AI matching secondary.
        prefs.autoEnableCloudSubtitles = true
        prefs.preferredPrimaryLanguage = .chineseSimplified
        prefs.preferredSecondaryLanguage = .english
        let nonAIPreferred = prefs.resolveInitialCloudTracks(from: [blankLan, aiZh, manualZh, aiEn, manualEn])
        #expect(nonAIPreferred.primaryLan == "zh-CN")
        #expect(nonAIPreferred.secondaryLan == "en-US")

        // 3. Falls back to AI matching track when no non-AI match is present.
        let aiFallback = prefs.resolveInitialCloudTracks(from: [manualEn, aiZh])
        #expect(aiFallback.primaryLan == "ai-zh")
        #expect(aiFallback.secondaryLan == "en-US")

        // 4. Falls back to first available valid cloud track when preferred language is absent.
        prefs.preferredPrimaryLanguage = .japanese
        prefs.preferredSecondaryLanguage = .english
        let firstFallback = prefs.resolveInitialCloudTracks(from: [blankLan, manualZh, aiEn])
        #expect(firstFallback.primaryLan == "zh-CN")
        #expect(firstFallback.secondaryLan == "ai-en")

        // 5. Secondary never duplicates primary and returns nil when no matching secondary exists.
        prefs.preferredPrimaryLanguage = .english
        prefs.preferredSecondaryLanguage = .english
        let singleEn = prefs.resolveInitialCloudTracks(from: [manualEn])
        #expect(singleEn.primaryLan == "en-US")
        #expect(singleEn.secondaryLan == nil)

        let dualEn = prefs.resolveInitialCloudTracks(from: [manualEn, aiEn])
        #expect(dualEn.primaryLan == "en-US")
        #expect(dualEn.secondaryLan == "ai-en")
    }

    @Test("PlayerSessionState.resetTransientSubtitleState preserves persisted auto-translation and locale settings")
    func sessionResetPreservesPersistedSubtitleSettings() throws {
        let suiteName = "com.swiftpili.tests.sessionReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = SubtitleStylePreferences(defaults: defaults)
        prefs.autoTranslateEnabled = true
        prefs.speechLocale = .japanese
        prefs.translationTargetLanguage = .english

        let state = PlayerSessionState(subtitlePreferences: prefs)
        #expect(state.isAutoTranslationEnabled == true)
        #expect(state.speechSubtitleLocale == .japanese)
        #expect(state.subtitleTranslationTargetLanguage == .english)

        state.secondarySubtitleLan = "en-US"
        state.secondarySubtitleText = "Previous line"
        state.isAutoTranslationEnabled = false
        state.loadGeneration += 1

        #expect(state.secondarySubtitleLan == nil)
        #expect(state.secondarySubtitleText == nil)
        #expect(state.isAutoTranslationEnabled == true)
        #expect(state.speechSubtitleLocale == .japanese)
        #expect(state.subtitleTranslationTargetLanguage == .english)
    }
}

// MARK: - Track 4: Dual-Track Cue Lookup & Speech Timeline Store

@Suite("Track 4: Dual-Track Subtitles & Speech Timeline")
struct Track4DualTrackAndSpeechTimelineTests {
    @Test("SubtitleCueIndex handles touching, overlapping, and unsorted cues accurately")
    func cueIndexTouchingAndOverlappingLookup() {
        let cues: [PlayerViewModel.SubtitleCue] = [
            .init(from: 5.0, to: 8.0, content: "Line B"),
            .init(from: 0.0, to: 10.0, content: "Sign banner"),
            .init(from: 2.0, to: 5.0, content: "Line A"),
        ]
        let index = SubtitleCueIndex(cues: cues)

        #expect(index.activeText(at: 1.0) == "Sign banner")
        #expect(index.activeText(at: 3.0) == "Sign banner\nLine A")
        #expect(index.activeText(at: 6.0) == "Sign banner\nLine B")
        #expect(index.activeText(at: 10.5) == nil)
        #expect(index.activeText(at: .nan) == nil)
    }

    @Test("PlayerViewModel dual-track lookup resolves primary and secondary imported tracks simultaneously")
    @MainActor
    func playerViewModelDualTrackBilingualLookup() throws {
        let vm = PlayerViewModel.shared
        let prefs = SubtitleStylePreferences.shared
        let savedAutoCloud = prefs.autoEnableCloudSubtitles
        let savedPrimaryLang = prefs.preferredPrimaryLanguage
        let savedSecondaryLang = prefs.preferredSecondaryLanguage
        let savedAutoTranslate = prefs.autoTranslateEnabled
        let savedAutoSpeech = prefs.autoSpeechMode
        vm.loadGeneration += 1
        defer {
            vm.turnOffAllSubtitles()
            prefs.autoEnableCloudSubtitles = savedAutoCloud
            prefs.preferredPrimaryLanguage = savedPrimaryLang
            prefs.preferredSecondaryLanguage = savedSecondaryLang
            prefs.autoTranslateEnabled = savedAutoTranslate
            prefs.autoSpeechMode = savedAutoSpeech
            vm.loadGeneration += 1
        }

        let primarySRT = """
        1
        00:00:01,000 --> 00:00:04,000
        你好世界

        2
        00:00:06,000 --> 00:00:08,000
        只有主字幕
        """
        let secondaryVTT = """
        WEBVTT

        00:02.000 --> 00:05.000
        Hello world
        """

        let primaryTrack = try vm.importLocalSubtitle(
            data: Data(primarySRT.utf8),
            fileName: "episode_zh.srt",
            assignToSecondaryIfPrimaryActive: false
        )
        let secondaryTrack = try vm.importLocalSubtitle(
            data: Data(secondaryVTT.utf8),
            fileName: "episode_en.vtt",
            assignToSecondaryIfPrimaryActive: true
        )

        #expect(vm.activeSubtitleLan == primaryTrack.id)
        #expect(vm.secondarySubtitleLan == secondaryTrack.id)
        #expect(vm.importedSubtitleTracks.count == 2)

        // Primary only at t = 1.5s
        vm.updateSubtitle(at: 1.5)
        #expect(vm.subtitleText == "你好世界")
        #expect(vm.secondarySubtitleText == nil)

        // Bilingual overlap at t = 3.0s
        vm.updateSubtitle(at: 3.0)
        #expect(vm.subtitleText == "你好世界")
        #expect(vm.secondarySubtitleText == "Hello world")

        // Secondary only at t = 4.5s
        vm.updateSubtitle(at: 4.5)
        #expect(vm.subtitleText == nil)
        #expect(vm.secondarySubtitleText == "Hello world")

        // Gap at t = 5.5s
        vm.updateSubtitle(at: 5.5)
        #expect(vm.subtitleText == nil)
        #expect(vm.secondarySubtitleText == nil)

        // Primary only at t = 7.0s
        vm.updateSubtitle(at: 7.0)
        #expect(vm.subtitleText == "只有主字幕")
        #expect(vm.secondarySubtitleText == nil)

        // Removing secondary track clears secondary output immediately while keeping primary intact.
        vm.removeImportedSubtitleTrack(id: secondaryTrack.id)
        #expect(vm.secondarySubtitleLan == nil)
        #expect(vm.secondarySubtitleText == nil)
        #expect(vm.activeSubtitleLan == primaryTrack.id)
    }

    @Test("SpeechSubtitleCueBuilder groups timed segments and SpeechSubtitleTimelineStore prefers finalized over volatile")
    func speechCueBuilderAndTimelineStore() {
        let segments: [SpeechSubtitleCueBuilder.TimedSegment] = [
            .init(text: "Hello", startOffset: 0.2, duration: 0.4),
            .init(text: "world.", startOffset: 0.65, duration: 0.45),
            .init(text: "Next", startOffset: 2.5, duration: 0.3),
            .init(text: "sentence", startOffset: 2.85, duration: 0.5),
        ]
        let cues = SpeechSubtitleCueBuilder.buildCues(from: segments, basePTS: 100.0)
        #expect(cues.count == 2)
        #expect(cues[0].content == "Hello world.")
        #expect(abs(cues[0].from - 100.2) < 1e-6)
        #expect(cues[1].content == "Next sentence")
        #expect(abs(cues[1].from - 102.5) < 1e-6)

        var store = SpeechSubtitleTimelineStore()
        store.setVolatile(.init(from: 105.0, to: 106.5, content: "Live partial..."))
        #expect(store.activeText(at: 105.5) == "Live partial...")

        store.appendFinalized(cues)
        #expect(store.activeText(at: 100.5) == "Hello world.")
        #expect(store.activeText(at: 105.5) == "Live partial...")

        store.clearVolatile()
        #expect(store.activeText(at: 105.5) == nil)
        #expect(store.activeText(at: 100.5) == "Hello world.")

        store.clearAll()
        #expect(store.activeText(at: 100.5) == nil)
    }
}

// MARK: - Track 4: AudioPCMSubtitleTap

@Suite("Track 4: AudioPCMSubtitleTap Mono Downmix & Non-Blocking Delivery")
struct Track4AudioPCMSubtitleTapTests {
    private static func makeFloat32Data(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test("Downmixes mono, stereo, and 4-channel interleaved Float32 PCM accurately including leading frame trim")
    func monoStereoAndMultiChannelDownmix() {
        // Stereo: (0.2, 0.6) -> 0.4; (-0.4, 0.4) -> 0.0; (1.0, 0.0) -> 0.5
        let stereoData = Self.makeFloat32Data([0.2, 0.6, -0.4, 0.4, 1.0, 0.0])
        let stereoMono = AudioPCMSubtitleTap.downmixInterleavedFloat32ToMono(
            pcm: stereoData,
            channels: 2
        )
        #expect(stereoMono.count == 3)
        #expect(abs(stereoMono[0] - 0.4) < 1e-6)
        #expect(abs(stereoMono[1] - 0.0) < 1e-6)
        #expect(abs(stereoMono[2] - 0.5) < 1e-6)

        // Trim first frame from stereo -> drops (0.2, 0.6)
        let trimmedStereo = AudioPCMSubtitleTap.downmixInterleavedFloat32ToMono(
            pcm: stereoData,
            channels: 2,
            skipLeadingFrames: 1
        )
        #expect(trimmedStereo.count == 2)
        #expect(abs(trimmedStereo[0] - 0.0) < 1e-6)
        #expect(abs(trimmedStereo[1] - 0.5) < 1e-6)

        // 4-channel downmix: (0.4, 0.8, 0.0, 0.4) -> avg 0.4
        let quadData = Self.makeFloat32Data([0.4, 0.8, 0.0, 0.4])
        let quadMono = AudioPCMSubtitleTap.downmixInterleavedFloat32ToMono(
            pcm: quadData,
            channels: 4
        )
        #expect(quadMono.count == 1)
        #expect(abs(quadMono[0] - 0.4) < 1e-6)

        // Unaligned Data slice fallback check
        var padded = Data([0xAA])
        padded.append(stereoData)
        let unalignedSlice = padded.dropFirst(1)
        let unalignedMono = AudioPCMSubtitleTap.downmixInterleavedFloat32ToMono(
            pcm: unalignedSlice,
            channels: 2
        )
        #expect(unalignedMono.count == 3)
        #expect(abs(unalignedMono[0] - 0.4) < 1e-6)
    }

    @Test("Delivers bounded non-blocking chunks, detects timeline jumps, and honors seek discontinuities")
    func nonBlockingBoundedDeliveryAndDiscontinuities() async {
        let tap = AudioPCMSubtitleTap()
        #expect(!tap.isActive)

        // Inactive ingest returns immediately without error.
        let oneFrameStereo = Self.makeFloat32Data([0.5, 0.5, 0.5, 0.5])
        tap.ingest(pcm: oneFrameStereo, pts: 0.0, sampleRate: 48_000, channels: 2)
        #expect(!tap.isActive)

        // Bounded stream capacity = 4: ingest 20 chunks synchronously without awaiting -> never blocks, keeps newest 4.
        let boundedStream = tap.makeStream(bufferingNewest: 4)
        #expect(tap.isActive)
        for index in 0..<20 {
            let pts = Double(index) * 0.02
            tap.ingest(pcm: oneFrameStereo, pts: pts, sampleRate: 48_000, channels: 2)
        }
        tap.deactivate()
        #expect(!tap.isActive)

        var boundedEvents: [AudioPCMSubtitleEvent] = []
        for await event in boundedStream {
            boundedEvents.append(event)
        }
        #expect(boundedEvents.count == 4)
        if case .pcm(let lastChunk) = boundedEvents.last {
            #expect(abs(lastChunk.pts - 19 * 0.02) < 1e-6)
        } else {
            Issue.record("Expected trailing PCM chunk in bounded bufferingNewest stream")
        }

        // Discontinuity propagation: explicit seek + automatic timeline jump detection.
        let discontinuityStream = tap.makeStream(bufferingNewest: 16)
        tap.ingest(pcm: oneFrameStereo, pts: 10.0, sampleRate: 48_000, channels: 2)
        tap.notifyDiscontinuity(reason: .seek, targetPTS: 45.0)
        tap.ingest(pcm: oneFrameStereo, pts: 45.0, sampleRate: 48_000, channels: 2)
        // Jump backwards by 20s without explicit notification -> triggers automatic timelineJump.
        tap.ingest(pcm: oneFrameStereo, pts: 25.0, sampleRate: 48_000, channels: 2)
        tap.deactivate()

        var events: [AudioPCMSubtitleEvent] = []
        for await event in discontinuityStream {
            events.append(event)
        }
        #expect(events.count == 5)
        if case .pcm(let c0) = events[0] {
            #expect(abs(c0.pts - 10.0) < 1e-6)
        } else {
            Issue.record("Expected initial PCM chunk at 10s")
        }
        #expect(events[1] == .discontinuity(reason: .seek, targetPTS: 45.0))
        if case .pcm(let c2) = events[2] {
            #expect(abs(c2.pts - 45.0) < 1e-6)
        } else {
            Issue.record("Expected post-seek PCM chunk at 45s")
        }
        #expect(events[3] == .discontinuity(reason: .timelineJump, targetPTS: 25.0))
        if case .pcm(let c4) = events[4] {
            #expect(abs(c4.pts - 25.0) < 1e-6)
        } else {
            Issue.record("Expected jumped PCM chunk at 25s")
        }
    }

    @Test("PCMBufferConverter converts 48kHz & 44.1kHz Float32 mono into 16kHz Int16 interleaved and Float32 non-interleaved")
    func pcmBufferConverterFormats() throws {
        func makeSineChunk(sampleRate: Double, frameCount: Int, pts: TimeInterval) -> AudioPCMSubtitleChunk {
            let samples = (0..<frameCount).map { index -> Float in
                sin(Float(2.0 * Double.pi * 440.0 * Double(index) / sampleRate)) * 0.5
            }
            return AudioPCMSubtitleChunk(monoSamples: samples, pts: pts, sampleRate: sampleRate)
        }

        // 1. 48kHz Float32 -> 16kHz Int16 interleaved (typical iOS 26 SpeechAnalyzer format)
        // First chunk has ~240 frames of FIR resampler priming delay (~1360/1600); subsequent chunks emit full ~1600.
        let int16Format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let int16Converter = PCMBufferConverter(targetFormat: int16Format)
        let converted48ToInt16 = try #require(
            int16Converter.convert(makeSineChunk(sampleRate: 48_000, frameCount: 4_800, pts: 10.0))
        )
        #expect(converted48ToInt16.format.commonFormat == .pcmFormatInt16)
        #expect(converted48ToInt16.format.isInterleaved)
        #expect(abs(converted48ToInt16.format.sampleRate - 16_000) < 0.5)
        #expect(converted48ToInt16.frameLength >= 1_200)
        if let int16Ptr = converted48ToInt16.int16ChannelData?[0] {
            var peak: Int32 = 0
            for i in 0..<Int(converted48ToInt16.frameLength) {
                peak = max(peak, abs(Int32(int16Ptr[i])))
            }
            #expect(peak > 5_000)
        } else {
            Issue.record("Expected valid int16ChannelData on converted Int16 interleaved buffer")
        }

        // Steady-state 2nd chunk + 1024-frame AAC quantum chunk -> both convert cleanly.
        let steadyInt16 = try #require(
            int16Converter.convert(makeSineChunk(sampleRate: 48_000, frameCount: 4_800, pts: 10.1))
        )
        #expect(steadyInt16.frameLength >= 1_550)
        let aacQuantumInt16 = try #require(
            int16Converter.convert(makeSineChunk(sampleRate: 48_000, frameCount: 1_024, pts: 10.2))
        )
        #expect(aacQuantumInt16.frameLength >= 300)

        // 2. 44.1kHz Float32 -> 16kHz Int16 interleaved (dynamic sample-rate switch)
        let converted441ToInt16 = try #require(
            int16Converter.convert(makeSineChunk(sampleRate: 44_100, frameCount: 4_410, pts: 10.3))
        )
        #expect(converted441ToInt16.format.commonFormat == .pcmFormatInt16)
        #expect(converted441ToInt16.frameLength >= 1_200)

        // 3. 48kHz Float32 -> 16kHz Float32 non-interleaved (SFSpeechAudioBufferRecognitionRequest format)
        let float16Format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let floatConverter = PCMBufferConverter(targetFormat: float16Format)
        let converted48ToFloat = try #require(
            floatConverter.convert(makeSineChunk(sampleRate: 48_000, frameCount: 4_800, pts: 20.0))
        )
        #expect(converted48ToFloat.format.commonFormat == .pcmFormatFloat32)
        #expect(!converted48ToFloat.format.isInterleaved)
        #expect(converted48ToFloat.frameLength >= 1_200)
        if let floatPtr = converted48ToFloat.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(converted48ToFloat.frameLength) {
                peak = max(peak, abs(floatPtr[i]))
            }
            #expect(peak > 0.25)
        } else {
            Issue.record("Expected valid floatChannelData on converted Float32 buffer")
        }
        let steadyFloat = try #require(
            floatConverter.convert(makeSineChunk(sampleRate: 48_000, frameCount: 4_800, pts: 20.1))
        )
        #expect(steadyFloat.frameLength >= 1_550)

        // 4. 16kHz Float32 passthrough
        let passthrough = try #require(
            floatConverter.convert(makeSineChunk(sampleRate: 16_000, frameCount: 1_600, pts: 20.1))
        )
        #expect(passthrough.frameLength == 1_600)
    }

    @Test("Lookahead audio bursts keep early untimed & timed volatile cues visible at current mediaTime")
    func lookaheadVolatileCueVisibility() {
        // Scenario: mediaTime = 20.5s, 10s of ahead-of-playback PCM (20..30s) was burst-fed immediately,
        // and SFSpeechRecognizer emits an early untimed partial (timestamp == 0, duration == 0).
        let untimedUpdate = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: "欢迎来到今天的节目",
            segments: [
                .init(text: "欢迎来到今天的节目", startOffset: 0, duration: 0),
            ],
            basePTS: 20.0,
            windowAudioDuration: 10.0,
            committedSegmentCount: 0,
            lastCommittedEndOffset: 0,
            lastPartialEndOffset: 0
        )
        let untimedVolatile = untimedUpdate.volatileCue
        #expect(untimedVolatile != nil)
        #expect(abs((untimedVolatile?.from ?? -1) - 20.0) < 1e-6)

        var store = SpeechSubtitleTimelineStore()
        store.setVolatile(untimedVolatile)
        #expect(store.activeText(at: 20.0) == "欢迎来到今天的节目")
        #expect(store.activeText(at: 20.5) == "欢迎来到今天的节目")
        #expect(store.activeText(at: 28.0) == "欢迎来到今天的节目")

        // Timed early partial during 10s lookahead burst: waits until cue.from (20.2s) and stays visible with recognition latency hold.
        let timedUpdate = SpeechSubtitleCueBuilder.buildLegacyPartialUpdate(
            formattedText: "Hello everyone",
            segments: [
                .init(text: "Hello", startOffset: 0.2, duration: 0.4),
                .init(text: "everyone", startOffset: 0.65, duration: 0.85),
            ],
            basePTS: 20.0,
            windowAudioDuration: 10.0,
            committedSegmentCount: 0,
            lastCommittedEndOffset: 0,
            lastPartialEndOffset: 0
        )
        let timedVolatile = timedUpdate.volatileCue
        #expect(timedVolatile != nil)
        #expect(abs((timedVolatile?.from ?? -1) - 20.2) < 1e-6)
        #expect((timedVolatile?.to ?? 0) >= 22.7)
        store.setVolatile(timedVolatile)
        #expect(store.activeText(at: 20.0) == nil)
        #expect(store.activeText(at: 20.2) == "Hello everyone")
        #expect(store.activeText(at: 21.8) == "Hello everyone")
        #expect(store.activeText(at: 25.5) == "Hello everyone")
    }

    @Test("LegacySpeechErrorDisposition falls back immediately on on-device errors 1101/203 and ignores benign 1110 silence")
    func legacyErrorDispositionFallback() {
        // Real-device error 1101 before any on-device result -> immediate fallback to System Speech.
        #expect(
            LegacySpeechErrorDisposition.classify(
                domain: "kAFAssistantErrorDomain",
                code: 1101,
                preferOnDevice: true,
                hasProducedResultWithOnDevice: false,
                hasProducedResultInWindow: false
            ) == .fallbackToServer
        )
        #expect(
            LegacySpeechErrorDisposition.classify(
                domain: "kAFAssistantErrorDomain",
                code: 203,
                preferOnDevice: true,
                hasProducedResultWithOnDevice: false,
                hasProducedResultInWindow: false
            ) == .fallbackToServer
        )
        // Benign 1110 "No speech detected" during silence does NOT downgrade on-device or count failure.
        #expect(
            LegacySpeechErrorDisposition.classify(
                domain: "kAFAssistantErrorDomain",
                code: 1110,
                preferOnDevice: true,
                hasProducedResultWithOnDevice: false,
                hasProducedResultInWindow: false
            ) == .ignoreBenignSilence
        )
        // Cancellation errors do not count as failures.
        #expect(
            LegacySpeechErrorDisposition.classify(
                domain: "kAFAssistantErrorDomain",
                code: 216,
                preferOnDevice: true,
                hasProducedResultWithOnDevice: false,
                hasProducedResultInWindow: false
            ) == .ignoreCancellation
        )
        // Once already in server fallback mode, real errors count toward failure escalation.
        #expect(
            LegacySpeechErrorDisposition.classify(
                domain: "kAFAssistantErrorDomain",
                code: 1101,
                preferOnDevice: false,
                hasProducedResultWithOnDevice: false,
                hasProducedResultInWindow: false
            ) == .countFailure
        )
    }

    @Test("AudioTimelinePCMSupply unread snapshot seeds AudioPCMSubtitleTap immediately at current read head with zero jump")
    func midPlaybackUnreadBufferSeeding() async {
        let sampleRate = 48_000.0
        let channels = 2
        let supply = AudioTimelinePCMSupply(
            defaultSampleRate: sampleRate,
            defaultChannels: channels,
            timelineEpsilon: 1024.0 / sampleRate
        )

        // Append 4 seconds of stereo PCM covering pts 20.0 ..< 24.0.
        let oneSecondFrames = Int(sampleRate)
        let stereoSecond = [Float](repeating: 0.4, count: oneSecondFrames * channels)
        let pcmData = Self.makeFloat32Data(stereoSecond)
        for offset in 0..<4 {
            let res = supply.append(
                pcm: pcmData,
                pts: 20.0 + Double(offset),
                context: AudioPCMAppend(sampleRate: sampleRate, channels: channels, outputFloor: 20.0)
            )
            #expect(res.rejection == nil)
        }

        // Simulate playback advancing 1.5s so unread buffer starts at pts = 21.5s (2.5s remaining).
        let pullFrames = Int(1.5 * sampleRate)
        var scratch = [Float](repeating: 0, count: pullFrames * channels)
        let pulled = scratch.withUnsafeMutableBufferPointer { ptr in
            supply.pullContent(frameCount: pullFrames, sampleRate: sampleRate, channels: channels, into: ptr.baseAddress!)
        }
        #expect(pulled.frames == pullFrames)

        let tap = AudioPCMSubtitleTap()
        tap.setOnStreamActivated { [weak supply] activatedTap in
            guard let supply else { return }
            activatedTap.seedChunks(supply.snapshotUnreadMonoChunks(maxSeconds: 12.0))
        }

        // Activating the stream immediately seeds unread PCM from 21.5s ..< 24.0s.
        let stream = tap.makeStream(bufferingNewest: AudioPCMSubtitleTap.defaultBufferCapacity)

        // Next newly decoded frame at pts = 24.0s should flow seamlessly without any timelineJump!
        let nextFrameData = Self.makeFloat32Data([Float](repeating: 0.6, count: 1_024 * channels))
        tap.ingest(pcm: nextFrameData, pts: 24.0, sampleRate: sampleRate, channels: channels)
        tap.deactivate()

        var pcmChunks: [AudioPCMSubtitleChunk] = []
        var discontinuityCount = 0
        for await event in stream {
            switch event {
            case .pcm(let chunk):
                pcmChunks.append(chunk)
            case .discontinuity:
                discontinuityCount += 1
            }
        }

        #expect(discontinuityCount == 0)
        #expect(!pcmChunks.isEmpty)
        #expect(abs((pcmChunks.first?.pts ?? -1) - 21.5) < 0.002)
        let expectedEnd = 24.0 + 1_024.0 / sampleRate
        #expect(abs((pcmChunks.last?.endPTS ?? -1) - expectedEnd) < 0.002)
        #expect(abs((pcmChunks.first?.monoSamples.first ?? 0) - 0.4) < 1e-5)
    }

    @Test("Zero middle-dot (U+00B7) characters remain across SwiftPili sources, Localizable.strings, and UI formatters")
    func zeroMiddleDotAcrossCodebaseAndFormatters() {
        // Verify formatted UI summary helpers emit zero middle dots.
        let vtTelemetry = VideoEnhancementTelemetry(
            activeModeLabel: "VT System",
            inputWidth: 1280,
            inputHeight: 720,
            outputWidth: 1920,
            outputHeight: 1080,
            inputFPS: 30,
            outputFPS: 60,
            smoothedProcessingMs: 4.2,
            isActive: true,
            degradationNote: "thermal",
            activeFrameInterpolationBackendLabel: "VT System"
        )
        let config = VideoEnhancementConfiguration(
            frameInterpolationEnabled: true,
            frameInterpolationBackend: .videoToolbox,
            interpolationRate: .fps60
        )
        let engineSummary = PlayerStatsOverlay.interpolationEngineSummary(for: vtTelemetry, configuration: config) ?? ""
        #expect(!engineSummary.unicodeScalars.contains("\u{00B7}"))
        #expect(!vtTelemetry.formattedSummary.unicodeScalars.contains("\u{00B7}"))
        #expect(!vtTelemetry.compactSummary.unicodeScalars.contains("\u{00B7}"))
        #expect(!VideoEnhancementBypassDisplay.pausedMenuLabel(for: "thermal").unicodeScalars.contains("\u{00B7}"))
        #expect(!VideoEnhancementBypassDisplay.pausedStatsLabel(for: "thermal").unicodeScalars.contains("\u{00B7}"))

        // On Simulator / host test runs where source tree is accessible, verify zero U+00B7 in SwiftPili/.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = repoRoot.appendingPathComponent("SwiftPili")
        let fm = FileManager.default
        if fm.fileExists(atPath: sourceRoot.path),
           let enumerator = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) {
            var offenders: [String] = []
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "swift" || ext == "strings" else { continue }
                var detectedEncoding = String.Encoding.utf8
                guard let content = (try? String(contentsOf: fileURL, encoding: .utf8))
                    ?? (try? String(contentsOf: fileURL, usedEncoding: &detectedEncoding)) else {
                    continue
                }
                guard content.unicodeScalars.contains("\u{00B7}") else { continue }
                let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() where line.unicodeScalars.contains("\u{00B7}") {
                    offenders.append("\(relativePath):\(index + 1)")
                }
            }
            #expect(
                offenders.isEmpty,
                "Found forbidden middle-dot (U+00B7) characters at:\n\(offenders.joined(separator: "\n"))"
            )
        }
    }

    @Test("Redesigned subtitle sheet and settings view maintain native picker and SettingsIcon design contracts")
    func subtitleUIRedesignContracts() {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sheetURL = repoRoot.appendingPathComponent("SwiftPili/Player/Subtitles/PlayerSubtitleSettingsSheet.swift")
        let settingsURL = repoRoot.appendingPathComponent("SwiftPili/Features/Mine/Views/SubtitleSettingsView.swift")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sheetURL.path), fm.fileExists(atPath: settingsURL.path) else {
            return
        }

        if let sheetSource = try? String(contentsOf: sheetURL, encoding: .utf8) {
            #expect(!sheetSource.contains("trackRoleCapsuleButton"))
            #expect(sheetSource.contains("player.subtitles.primary.off"))
            #expect(sheetSource.contains("player.subtitles.secondaryPicker"))
            #expect(sheetSource.contains("player.subtitles.importButton"))
            #expect(sheetSource.contains("player.subtitles.styleAndDefaults"))
        }

        if let settingsSource = try? String(contentsOf: settingsURL, encoding: .utf8) {
            #expect(!settingsSource.contains("previewSection"))
            #expect(!settingsSource.contains("LinearGradient"))
            #expect(settingsSource.contains("SettingsIcon(symbol:"))
            #expect(settingsSource.contains(".readableFormWidth()"))
        }
    }
}

// MARK: - Track 4: Bilibili Cloud CC Decoding & On-Device Bilingual Translation

@Suite("Track 4: Bilibili Cloud CC Subtitles & Auto-Translation", .serialized)
struct Track4BilibiliCCAndTranslationTests {
    @Test("SubtitleItem decodes subtitle_url_v2 fallback, id_str, ai_type, and isAIGenerated")
    func subtitleItemDecodingAndURLNormalization() throws {
        let json = """
        {
          "subtitles": [
            {
              "id": 1234567890123,
              "id_str": "1234567890123",
              "lan": "ai-en",
              "lan_doc": "English",
              "subtitle_url": "",
              "subtitle_url_v2": "//aisubtitle.hdslb.com/bfs/ai_subtitle/demo_en.json",
              "ai_type": 1,
              "ai_status": 2
            },
            {
              "id": 987654321,
              "lan": "zh-CN",
              "lan_doc": "中文（中国）",
              "subtitle_url": "http://aisubtitle.hdslb.com/bfs/subtitle/demo_zh.json",
              "ai_type": 0,
              "ai_status": 0
            },
            {
              "lan": "ai-ja",
              "lan_doc": "日本語 (AI)",
              "subtitle_url_v2": "https://aisubtitle.hdslb.com/bfs/ai_subtitle/demo_ja.json"
            }
          ]
        }
        """

        let box = try JSONDecoder().decode(PlayerV2Info.SubtitleBox.self, from: Data(json.utf8))
        let items = try #require(box.subtitles)
        #expect(items.count == 3)

        // Item 0: empty subtitle_url falls back to subtitle_url_v2; ai_type=1 -> isAIGenerated
        #expect(items[0].id == 1234567890123)
        #expect(items[0].idStr == "1234567890123")
        #expect(items[0].lan == "ai-en")
        #expect(items[0].subtitleUrl == "//aisubtitle.hdslb.com/bfs/ai_subtitle/demo_en.json")
        #expect(items[0].aiType == 1)
        #expect(items[0].aiStatus == 2)
        #expect(items[0].isAIGenerated == true)
        #expect(items[0].menuDisplayTitle == "English (AI)")

        // Item 1: manual subtitle (ai_type == 0, non-ai lan)
        #expect(items[1].isAIGenerated == false)
        #expect(items[1].subtitleUrl == "http://aisubtitle.hdslb.com/bfs/subtitle/demo_zh.json")
        #expect(items[1].menuDisplayTitle == "中文（中国）")

        // Item 2: nil subtitle_url falls back to subtitle_url_v2; ai- prefix -> isAIGenerated without duplicate (AI)
        #expect(items[2].isAIGenerated == true)
        #expect(items[2].subtitleUrl == "https://aisubtitle.hdslb.com/bfs/ai_subtitle/demo_ja.json")
        #expect(items[2].menuDisplayTitle == "日本語 (AI)")

        // URL normalization upgrades // and http:// to https:// while preserving file://
        #expect(
            PlayerViewModel.normalizedBilibiliSubtitleURLString("//aisubtitle.hdslb.com/a.json")
                == "https://aisubtitle.hdslb.com/a.json"
        )
        #expect(
            PlayerViewModel.normalizedBilibiliSubtitleURLString("http://aisubtitle.hdslb.com/b.json")
                == "https://aisubtitle.hdslb.com/b.json"
        )
        #expect(
            PlayerViewModel.normalizedBilibiliSubtitleURLString("file:///tmp/offline_sub.json")
                == "file:///tmp/offline_sub.json"
        )
    }

    @Test("SubtitleTranslationBatchPlanner prioritizes playback window cues first and streams background batches")
    func translationBatchPlannerWindowPrioritization() {
        let cues: [PlayerViewModel.SubtitleCue] = [
            .init(from: 2.0, to: 4.0, content: "Early intro line"),
            .init(from: 10.0, to: 14.0, content: "Second early line"),
            .init(from: 116.0, to: 118.0, content: "Recent window line"),
            .init(from: 119.0, to: 122.0, content: "Active right now"),
            .init(from: 123.0, to: 126.0, content: "♪♪♪"),
            .init(from: 128.0, to: 132.0, content: "Upcoming line one"),
            .init(from: 140.0, to: 145.0, content: "Upcoming line two"),
            .init(from: 200.0, to: 205.0, content: "Later video line"),
        ]

        var handled = Set<String>()

        // Focus at t = 120s: priority window is [115s, 180s].
        // Order must be: active now -> upcoming -> recent; non-translatable "♪♪♪" skipped.
        let batch1 = SubtitleTranslationBatchPlanner.nextBatch(
            cues: cues,
            focusTime: 120.0,
            alreadyHandled: { handled.contains($0) },
            priorityBatchSize: 20,
            backgroundBatchSize: 30
        )
        #expect(batch1 == [
            "Active right now",
            "Upcoming line one",
            "Upcoming line two",
            "Recent window line",
        ])

        for item in batch1 {
            handled.insert(item)
        }

        // Next batch after priority window completes: forward after 180s first, then wrap around before 115s.
        let batch2 = SubtitleTranslationBatchPlanner.nextBatch(
            cues: cues,
            focusTime: 120.0,
            alreadyHandled: { handled.contains($0) },
            priorityBatchSize: 20,
            backgroundBatchSize: 30
        )
        #expect(batch2 == [
            "Later video line",
            "Early intro line",
            "Second early line",
        ])

        for item in batch2 {
            handled.insert(item)
        }

        // Everything translatable is now complete.
        let batch3 = SubtitleTranslationBatchPlanner.nextBatch(
            cues: cues,
            focusTime: 120.0,
            alreadyHandled: { handled.contains($0) }
        )
        #expect(batch3.isEmpty)
    }

    @Test("SubtitleTranslationCache enforces LRU eviction, recency promotion, and target-language isolation")
    func translationCacheLRUEvictionAndIsolation() {
        var cache = SubtitleTranslationCache(capacity: 2)

        cache.set("你好", for: "Hello", targetLanguageID: "zh-Hans")
        cache.set("世界", for: "World", targetLanguageID: "zh-Hans")
        #expect(cache.count == 2)

        // Access "Hello" to promote it ahead of "World".
        #expect(cache.value(for: "  Hello \n", targetLanguageID: "zh-Hans") == "你好")

        // Inserting a third entry evicts "World" (least recently used), keeping "Hello".
        cache.set("こんにちは", for: "Hello", targetLanguageID: "ja")
        #expect(cache.count == 2)
        #expect(cache.peek(for: "World", targetLanguageID: "zh-Hans") == nil)
        #expect(cache.peek(for: "Hello", targetLanguageID: "zh-Hans") == "你好")
        #expect(cache.peek(for: "Hello", targetLanguageID: "ja") == "こんにちは")
    }

    @Test("PlayerViewModel dual-track Bilibili CC selection and auto-translation secondary cue lookup")
    @MainActor
    func playerViewModelDualTrackBilibiliCCAndAutoTranslation() async throws {
        let vm = PlayerViewModel.shared
        let prefs = SubtitleStylePreferences.shared
        let savedAutoCloud = prefs.autoEnableCloudSubtitles
        let savedPrimaryLang = prefs.preferredPrimaryLanguage
        let savedSecondaryLang = prefs.preferredSecondaryLanguage
        let savedAutoTranslate = prefs.autoTranslateEnabled
        let savedAutoSpeech = prefs.autoSpeechMode
        let previousAvailable = vm.availableSubtitles
        let previousTarget = vm.subtitleTranslationTargetLanguage
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track4-bili-cc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        vm.loadGeneration += 1
        defer {
            vm.turnOffAllSubtitles()
            vm.session.subtitleTranslationService.clearCache()
            vm.availableSubtitles = previousAvailable
            vm.setSubtitleTranslationTargetLanguage(previousTarget)
            prefs.autoEnableCloudSubtitles = savedAutoCloud
            prefs.preferredPrimaryLanguage = savedPrimaryLang
            prefs.preferredSecondaryLanguage = savedSecondaryLang
            prefs.autoTranslateEnabled = savedAutoTranslate
            prefs.autoSpeechMode = savedAutoSpeech
            vm.loadGeneration += 1
            try? FileManager.default.removeItem(at: tempDir)
        }

        let enFile = tempDir.appendingPathComponent("ai_en.json")
        let zhFile = tempDir.appendingPathComponent("zh_cn.json")
        let enJSON = """
        {"body": [
          {"from": 1.0, "to": 4.0, "content": "Hello everyone"},
          {"from": 5.0, "to": 8.0, "content": "Welcome back"}
        ]}
        """
        let zhJSON = """
        {"body": [
          {"from": 1.0, "to": 4.0, "content": "大家好"},
          {"from": 5.0, "to": 8.0, "content": "欢迎回来"}
        ]}
        """
        try Data(enJSON.utf8).write(to: enFile)
        try Data(zhJSON.utf8).write(to: zhFile)

        vm.availableSubtitles = [
            PlayerV2Info.SubtitleBox.SubtitleItem(
                lan: "ai-en",
                lanDoc: "English",
                subtitleUrl: enFile.absoluteString,
                aiType: 1
            ),
            PlayerV2Info.SubtitleBox.SubtitleItem(
                lan: "zh-CN",
                lanDoc: "中文",
                subtitleUrl: zhFile.absoluteString,
                aiType: 0
            ),
        ]

        // 1. Dual-track Bilibili CC selection via toggle helpers
        await vm.togglePrimarySubtitleTrack(id: "ai-en")
        await vm.toggleSecondarySubtitleTrack(id: "zh-CN")
        vm.updateSubtitle(at: 2.0)

        #expect(vm.activeSubtitleLan == "ai-en")
        #expect(vm.secondarySubtitleLan == "zh-CN")
        #expect(vm.subtitleText == "Hello everyone")
        #expect(vm.secondarySubtitleText == "大家好")
        #expect(vm.activeSubtitleSummaryLabel == "English (AI) + 中文")

        // 2. Enabling auto-translation clears manual secondary track and serves cached translations
        vm.setSubtitleTranslationTargetLanguage(.chineseSimplified)
        vm.session.subtitleTranslationService.storeCachedTranslation(
            "各位好（自动翻译）",
            for: "Hello everyone",
            targetLanguage: .chineseSimplified
        )
        vm.session.subtitleTranslationService.storeCachedTranslation(
            "欢迎回来（自动翻译）",
            for: "Welcome back",
            targetLanguage: .chineseSimplified
        )
        vm.setAutoSubtitleTranslationEnabled(true)

        #expect(vm.secondarySubtitleLan == nil)
        #expect(vm.isAutoTranslationEnabled == true)
        #expect(vm.isAutoTranslationActive == true)
        #expect(vm.subtitleTranslationSessionKey?.sourceIdentifier == "en")
        #expect(vm.subtitleTranslationSessionKey?.targetIdentifier == "zh-Hans")

        vm.updateSubtitle(at: 2.0)
        #expect(vm.subtitleText == "Hello everyone")
        #expect(vm.secondarySubtitleText == "各位好（自动翻译）")

        vm.updateSubtitle(at: 6.5)
        #expect(vm.subtitleText == "Welcome back")
        #expect(vm.secondarySubtitleText == "欢迎回来（自动翻译）")

        // 3. Selecting a manual secondary track disables auto-translation cleanly
        await vm.toggleSecondarySubtitleTrack(id: "zh-CN")
        #expect(vm.isAutoTranslationEnabled == false)
        #expect(vm.secondarySubtitleLan == "zh-CN")
        vm.updateSubtitle(at: 2.0)
        #expect(vm.secondarySubtitleText == "大家好")

        // 4. Turning off all subtitles resets both tracks and auto-translation
        vm.turnOffAllSubtitles()
        #expect(!vm.hasAnyActiveSubtitle)
        #expect(!vm.isAutoTranslationEnabled)
        #expect(vm.subtitleText == nil)
        #expect(vm.secondarySubtitleText == nil)
        #expect(prefs.autoEnableCloudSubtitles == false)
        #expect(prefs.preferredSecondaryLanguage == .none)
        #expect(prefs.autoTranslateEnabled == false)
        #expect(prefs.autoSpeechMode == .off)
    }

    @Test("PlayerViewModel persists cloud subtitle choices and auto-applies them on the next video load")
    @MainActor
    func playerViewModelCrossVideoSubtitlePersistenceAndAutoApply() async throws {
        let vm = PlayerViewModel.shared
        let prefs = SubtitleStylePreferences.shared
        let savedAutoCloud = prefs.autoEnableCloudSubtitles
        let savedPrimaryLang = prefs.preferredPrimaryLanguage
        let savedSecondaryLang = prefs.preferredSecondaryLanguage
        let savedAutoTranslate = prefs.autoTranslateEnabled
        let savedAutoSpeech = prefs.autoSpeechMode
        let previousAvailable = vm.availableSubtitles
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("track4-cross-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            vm.turnOffAllSubtitles()
            vm.availableSubtitles = previousAvailable
            prefs.autoEnableCloudSubtitles = savedAutoCloud
            prefs.preferredPrimaryLanguage = savedPrimaryLang
            prefs.preferredSecondaryLanguage = savedSecondaryLang
            prefs.autoTranslateEnabled = savedAutoTranslate
            prefs.autoSpeechMode = savedAutoSpeech
            vm.loadGeneration += 1
            try? FileManager.default.removeItem(at: tempDir)
        }

        let zhFile = tempDir.appendingPathComponent("zh.json")
        let enFile = tempDir.appendingPathComponent("en.json")
        try Data(#"{"body":[{"from":1.0,"to":4.0,"content":"你好下一集"}]}"#.utf8).write(to: zhFile)
        try Data(#"{"body":[{"from":1.0,"to":4.0,"content":"Hello next episode"}]}"#.utf8).write(to: enFile)

        let tracks = [
            PlayerV2Info.SubtitleBox.SubtitleItem(
                lan: "zh-CN", lanDoc: "中文", subtitleUrl: zhFile.absoluteString, aiType: 0
            ),
            PlayerV2Info.SubtitleBox.SubtitleItem(
                lan: "en-US", lanDoc: "English", subtitleUrl: enFile.absoluteString, aiType: 0
            ),
        ]

        // Video 1: user selects Chinese primary and English secondary.
        vm.loadGeneration += 1
        vm.availableSubtitles = tracks
        await vm.selectSubtitle(tracks[0])
        await vm.selectSecondarySubtitleTrack(id: "en-US")

        #expect(prefs.autoEnableCloudSubtitles == true)
        #expect(prefs.preferredPrimaryLanguage == .chineseSimplified)
        #expect(prefs.preferredSecondaryLanguage == .english)

        // Video 2: simulated new video load resets active tracks, then auto-applies persisted choices.
        vm.loadGeneration += 1
        vm.activeSubtitleLan = nil
        vm.subtitleCues = []
        vm.subtitleText = nil
        vm.availableSubtitles = tracks
        let nextGen = vm.loadGeneration
        await vm.applyPersistedSubtitlePreferences(for: tracks, expectedGeneration: nextGen)
        vm.updateSubtitle(at: 2.0)

        #expect(vm.activeSubtitleLan == "zh-CN")
        #expect(vm.secondarySubtitleLan == "en-US")
        #expect(vm.subtitleText == "你好下一集")
        #expect(vm.secondarySubtitleText == "Hello next episode")

        // Fallback on Video 3 (only English available) must NOT overwrite preferredPrimaryLanguage.
        vm.loadGeneration += 1
        vm.activeSubtitleLan = nil
        vm.subtitleCues = []
        vm.subtitleText = nil
        let englishOnly = [tracks[1]]
        vm.availableSubtitles = englishOnly
        await vm.applyPersistedSubtitlePreferences(for: englishOnly, expectedGeneration: vm.loadGeneration)

        #expect(vm.activeSubtitleLan == "en-US")
        #expect(vm.secondarySubtitleLan == nil)
        #expect(prefs.preferredPrimaryLanguage == .chineseSimplified)
        #expect(prefs.preferredSecondaryLanguage == .english)

        // Malformed subtitle item (nil URL) must not wipe persisted preferences.
        let malformedItem = PlayerV2Info.SubtitleBox.SubtitleItem(
            lan: "ja", lanDoc: "日本語", subtitleUrl: nil, aiType: 0
        )
        await vm.selectSubtitle(malformedItem)
        #expect(vm.activeSubtitleLan == nil)
        #expect(prefs.autoEnableCloudSubtitles == true)
        #expect(prefs.preferredPrimaryLanguage == .chineseSimplified)
        #expect(prefs.preferredSecondaryLanguage == .english)

        // Explicit selectSubtitle(nil) turns off all subtitles and clears persisted auto behavior.
        await vm.selectSubtitle(tracks[0])
        await vm.selectSecondarySubtitleTrack(id: "en-US")
        await vm.selectSubtitle(nil)
        #expect(!vm.hasAnyActiveSubtitle)
        #expect(!vm.isAutoTranslationEnabled)
        #expect(prefs.autoEnableCloudSubtitles == false)
        #expect(prefs.preferredSecondaryLanguage == .none)
        #expect(prefs.autoTranslateEnabled == false)
        #expect(prefs.autoSpeechMode == .off)
    }
}
