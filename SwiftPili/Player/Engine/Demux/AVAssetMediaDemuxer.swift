import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Path A **A1c** demux: `AVURLAsset` + `AVAssetReader` with **decompressed**
/// samples for Demand bring-up (no FFmpeg dual-link, no VT format plumbing).
///
/// - Video track output: BGRA `CVPixelBuffer` (pass-through video decoder).
/// - Audio track output: interleaved Float32 PCM @ 48 kHz stereo when possible.
///
/// Dual-URL friendly (video asset + optional audio asset). Does **not** import
/// SwiftVLC / SmartCDN / FFmpeg.
///
/// Seek recreates readers with a new `timeRange`. `startPosition` is honored at
/// open the same way. **sidx / fragment index:** future A4 work.
actor AVAssetMediaDemuxer: MediaDemuxing {
    // This demuxer does not own speculative VOD range transfers.
    func multiConnectionTelemetry() async -> MultiConnectionTelemetry { .unsupported }
    func setMultiConnectionQuiet(_ quiet: Bool) async {}
    func updateMultiConnectionPlayback(position: TimeInterval, rate: Float) async {}
    func cancelMultiConnectionPrefetching() async {}

    private(set) var duration: TimeInterval = 0
    private(set) var isEOF = false

    private var opened = false
    private var videoReader: AVAssetReader?
    private var audioReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var hasAudioTrack = false
    private var videoURL: URL?
    private var audioURL: URL?
    private var headers: [String: String] = [:]
    /// Cumulative sample bytes observed on pump (A7 stats; decompressed size).
    private(set) var bytesRead: Int64 = 0

    /// Open timeout so a dead host fails closed without hanging unit tests.
    private let openTimeoutNanoseconds: UInt64 = 8_000_000_000

    /// Engine PCM target (matches `MediaEngineSession.EnginePCM` / EngineAudio).
    private let pcmSampleRate: Double = 48_000
    private let pcmChannels: Int = 2

    func open(_ request: MediaOpenRequest) async throws {
        await close()
        opened = true
        isEOF = false
        bytesRead = 0
        videoURL = request.videoURL
        audioURL = request.audioURL
        headers = request.headers
        hasAudioTrack = request.audioURL != nil

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try await self.installReaders(
                        videoURL: request.videoURL,
                        audioURL: request.audioURL,
                        headers: request.headers,
                        start: max(0, request.startPosition)
                    )
                }
                group.addTask { [openTimeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: openTimeoutNanoseconds)
                    throw MediaEngineError.demuxFailed(
                        "AVAsset open timed out for \(request.videoURL.host ?? "?")"
                    )
                }
                try await group.next()
                group.cancelAll()
            }
        } catch let err as MediaEngineError {
            await close()
            throw err
        } catch is CancellationError {
            await close()
            throw MediaEngineError.demuxFailed("AVAsset open cancelled")
        } catch {
            await close()
            throw MediaEngineError.demuxFailed(error.localizedDescription)
        }
    }

    func pump(contentBudget: TimeInterval) async throws -> [MediaPacket] {
        guard opened else {
            throw MediaEngineError.stopped
        }
        guard contentBudget > 0, !isEOF else {
            return []
        }

        var packets: [MediaPacket] = []
        var videoBudget = contentBudget
        var audioBudget = hasAudioTrack ? contentBudget : 0

        while videoBudget > 0 || audioBudget > 0 {
            var progressed = false

            if videoBudget > 0, let output = videoOutput {
                if let sample = output.copyNextSampleBuffer() {
                    if let packet = makePacket(from: sample, track: .video) {
                        if packet.duration <= videoBudget + 1e-12 {
                            packets.append(packet)
                            videoBudget -= packet.duration
                            bytesRead += Int64(max(packet.data.count, 1))
                            progressed = true
                        } else {
                            videoBudget = 0
                        }
                    }
                } else {
                    videoBudget = 0
                }
            } else {
                videoBudget = 0
            }

            if hasAudioTrack, audioBudget > 0, let output = audioOutput {
                if let sample = output.copyNextSampleBuffer() {
                    if let packet = makePacket(from: sample, track: .audio) {
                        if packet.duration <= audioBudget + 1e-12 {
                            packets.append(packet)
                            audioBudget -= packet.duration
                            bytesRead += Int64(packet.data.count)
                            progressed = true
                        } else {
                            audioBudget = 0
                        }
                    }
                } else {
                    audioBudget = 0
                }
            } else if hasAudioTrack {
                audioBudget = 0
            }

            if !progressed {
                break
            }
        }

        refreshEOF()
        return packets
    }

    func seek(to mediaTime: TimeInterval) async throws {
        guard opened, let videoURL else {
            throw MediaEngineError.stopped
        }
        let start = max(0, mediaTime)
        try await installReaders(
            videoURL: videoURL,
            audioURL: audioURL,
            headers: headers,
            start: start
        )
        isEOF = false
        refreshEOF()
    }

    func close() async {
        videoReader?.cancelReading()
        audioReader?.cancelReading()
        videoReader = nil
        audioReader = nil
        videoOutput = nil
        audioOutput = nil
        opened = false
        isEOF = true
        hasAudioTrack = false
        duration = 0
        videoURL = nil
        audioURL = nil
        headers = [:]
    }

    // MARK: - Readers

    private func installReaders(
        videoURL: URL,
        audioURL: URL?,
        headers: [String: String],
        start: TimeInterval
    ) async throws {
        videoReader?.cancelReading()
        audioReader?.cancelReading()
        videoReader = nil
        audioReader = nil
        videoOutput = nil
        audioOutput = nil

        let videoAsset = makeAsset(url: videoURL, headers: headers)
        let videoMeta = try await loadAssetBasics(videoAsset)
        var totalDuration = videoMeta.durationSeconds

        let vReader = try await makeReader(
            asset: videoAsset,
            mediaType: .video,
            start: start,
            assetDuration: videoMeta.durationCM
        )
        videoReader = vReader.reader
        videoOutput = vReader.output

        if let audioURL {
            let audioAsset = makeAsset(url: audioURL, headers: headers)
            do {
                let audioMeta = try await loadAssetBasics(audioAsset)
                if audioMeta.durationSeconds > 0 {
                    totalDuration = totalDuration > 0
                        ? min(totalDuration, audioMeta.durationSeconds)
                        : audioMeta.durationSeconds
                }
                let aReader = try await makeReader(
                    asset: audioAsset,
                    mediaType: .audio,
                    start: start,
                    assetDuration: audioMeta.durationCM
                )
                audioReader = aReader.reader
                audioOutput = aReader.output
                hasAudioTrack = true
            } catch {
                hasAudioTrack = false
                audioReader = nil
                audioOutput = nil
                PlayerLog.log(
                    "[PathA] AVAsset audio reader failed: \(error.localizedDescription)"
                )
            }
        } else {
            hasAudioTrack = false
        }

        duration = totalDuration
    }

    private func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        // Diagnostics only — do not log signed query values (PlayerLog redacts, but
        // keep keys/host/ext so we can classify format vs network without secrets).
        PlayerLog.log(
            "[PathA] AVAsset make host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") " +
            "ext=\(url.pathExtension.isEmpty ? "-" : url.pathExtension) " +
            "pathEnds=\(url.lastPathComponent.prefix(48)) " +
            "queryKeys=\(Self.queryKeys(url)) " +
            "headerKeys=\(headers.keys.sorted().joined(separator: ",")) " +
            "cookieJarMatch=\(Self.cookieJarMatchSummary(for: url))"
        )
        return AVURLAsset(url: url, options: options.isEmpty ? nil : options)
    }

    private struct AssetMeta {
        var durationCM: CMTime
        var durationSeconds: TimeInterval
    }

    private func loadAssetBasics(_ asset: AVURLAsset) async throws -> AssetMeta {
        let host = asset.url.host ?? "?"
        // Stage loads so log pinpoints which property threw (playable vs duration vs tracks).
        do {
            PlayerLog.log("[PathA] AVAsset load begin host=\(host) stage=isPlayable")
            let isPlayable = try await asset.load(.isPlayable)
            PlayerLog.log(
                "[PathA] AVAsset load host=\(host) stage=isPlayable ok=\(isPlayable)"
            )

            PlayerLog.log("[PathA] AVAsset load host=\(host) stage=duration")
            let durationCM = try await asset.load(.duration)
            let durationSeconds = seconds(from: durationCM)
            PlayerLog.log(
                "[PathA] AVAsset load host=\(host) stage=duration ok " +
                "sec=\(String(format: "%.3f", durationSeconds)) " +
                "valid=\(CMTIME_IS_VALID(durationCM)) numeric=\(CMTIME_IS_NUMERIC(durationCM))"
            )

            PlayerLog.log("[PathA] AVAsset load host=\(host) stage=tracks")
            let tracks = try await asset.load(.tracks)
            let mediaTypes = tracks.map(\.mediaType.rawValue).joined(separator: ",")
            PlayerLog.log(
                "[PathA] AVAsset load host=\(host) stage=tracks ok " +
                "count=\(tracks.count) types=[\(mediaTypes)]"
            )

            if !isPlayable, tracks.isEmpty {
                PlayerLog.log(
                    "[PathA] AVAsset reject host=\(host) notPlayable+emptyTracks " +
                    "errDetail=none"
                )
                throw MediaEngineError.demuxFailed(
                    "AVAsset not playable and has no tracks host=\(host)"
                )
            }
            if !isPlayable {
                // Still try — some progressive assets report isPlayable=false briefly.
                PlayerLog.log(
                    "[PathA] AVAsset warn host=\(host) isPlayable=false " +
                    "tracks=\(tracks.count) — continuing"
                )
            }
            return AssetMeta(
                durationCM: durationCM,
                durationSeconds: durationSeconds
            )
        } catch let err as MediaEngineError {
            throw err
        } catch {
            let detail = Self.describeError(error)
            PlayerLog.log(
                "[PathA] AVAsset load FAILED host=\(host) \(detail)"
            )
            throw MediaEngineError.demuxFailed(
                "AVAsset load failed host=\(host): \(detail)"
            )
        }
    }

    private func makeReader(
        asset: AVURLAsset,
        mediaType: AVMediaType,
        start: TimeInterval,
        assetDuration: CMTime
    ) async throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let host = asset.url.host ?? "?"
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            let detail = Self.describeError(error)
            PlayerLog.log(
                "[PathA] AVAsset loadTracks(\(mediaType.rawValue)) FAILED host=\(host) \(detail)"
            )
            throw MediaEngineError.demuxFailed(
                "loadTracks(\(mediaType.rawValue)) host=\(host): \(detail)"
            )
        }
        guard let track = tracks.first else {
            PlayerLog.log(
                "[PathA] AVAsset no \(mediaType.rawValue) track host=\(host) " +
                "allTrackCount unavailable-at-this-stage"
            )
            throw MediaEngineError.demuxFailed(
                "no \(mediaType.rawValue) track host=\(host)"
            )
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            let detail = Self.describeError(error)
            PlayerLog.log(
                "[PathA] AVAssetReader init FAILED host=\(host) media=\(mediaType.rawValue) \(detail)"
            )
            throw MediaEngineError.demuxFailed(
                "AVAssetReader init host=\(host) media=\(mediaType.rawValue): \(detail)"
            )
        }

        // Decompress at the reader so Demand bring-up does not need VT SPS/PPS
        // or AAC bitstream plumbing yet (pass-through decoders).
        let outputSettings: [String: Any]
        switch mediaType {
        case .video:
            outputSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        case .audio:
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: pcmSampleRate,
                AVNumberOfChannelsKey: pcmChannels
            ]
        default:
            outputSettings = [:]
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings.isEmpty ? nil : outputSettings
        )
        // Must copy while session retains CMSampleBuffer image buffers across pump
        // cycles (pass-through BGRA). Revisit zero-copy only with tight lifetimes
        // after compressed demux + VT (A2b) — copy is costly on 4K.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MediaEngineError.demuxFailed("cannot add \(mediaType.rawValue) track output")
        }
        reader.add(output)

        if start > 0.001 {
            let natural = (try? await track.load(.naturalTimeScale)) ?? 600
            let timescale = natural > 0 ? natural : 600
            let startCM = CMTime(seconds: start, preferredTimescale: timescale)
            let end = assetDuration
            if CMTIME_IS_NUMERIC(end), end > startCM {
                reader.timeRange = CMTimeRange(start: startCM, end: end)
            } else if CMTIME_IS_NUMERIC(end), end <= startCM {
                reader.timeRange = CMTimeRange(start: end, duration: .zero)
            } else {
                reader.timeRange = CMTimeRange(start: startCM, duration: .positiveInfinity)
            }
        }

        guard reader.startReading() else {
            let detail = reader.error.map(Self.describeError) ?? "err=nil status=\(reader.status.rawValue)"
            PlayerLog.log(
                "[PathA] AVAssetReader startReading FAILED host=\(host) " +
                "media=\(mediaType.rawValue) \(detail)"
            )
            throw MediaEngineError.demuxFailed(
                "AVAssetReader startReading host=\(host) media=\(mediaType.rawValue): \(detail)"
            )
        }
        PlayerLog.log(
            "[PathA] AVAssetReader started host=\(host) media=\(mediaType.rawValue) " +
            "start=\(String(format: "%.2f", start))"
        )
        return (reader, output)
    }

    // MARK: - Diagnostics (no signed secrets)

    /// Flatten NSError chain for console soak — domain/code/desc + underlying.
    private static func describeError(_ error: Error) -> String {
        var parts: [String] = []
        parts.append("type=\(String(describing: type(of: error)))")
        parts.append("desc=\(error.localizedDescription)")
        let ns = error as NSError
        parts.append("domain=\(ns.domain)")
        parts.append("code=\(ns.code)")
        if let reason = ns.localizedFailureReason, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        // Useful AVFoundation / URL keys only (skip huge data blobs / tokens).
        let interestingKeys: [String] = [
            NSUnderlyingErrorKey,
            NSURLErrorKey,
            NSURLErrorFailingURLErrorKey,
            NSURLErrorFailingURLStringErrorKey,
            NSLocalizedDescriptionKey,
            "NSLocalizedFailureReason",
            "AVErrorMediaTypeKey",
            "AVErrorFileSizeKey",
            "NSDebugDescription",
        ]
        for key in interestingKeys {
            guard let value = ns.userInfo[key] else { continue }
            if let nested = value as? NSError {
                parts.append(
                    "underlying={domain=\(nested.domain) code=\(nested.code) " +
                    "desc=\(nested.localizedDescription)}"
                )
                if let deeper = nested.userInfo[NSUnderlyingErrorKey] as? NSError {
                    parts.append(
                        "underlying2={domain=\(deeper.domain) code=\(deeper.code) " +
                        "desc=\(deeper.localizedDescription)}"
                    )
                }
            } else if let url = value as? URL {
                parts.append("\(key)=host=\(url.host ?? "?") ext=\(url.pathExtension)")
            } else if let s = value as? String {
                // Cap length; PlayerLog also redacts query tokens.
                let clipped = s.count > 160 ? String(s.prefix(160)) + "…" : s
                parts.append("\(key)=\(clipped)")
            } else {
                parts.append("\(key)=\(String(describing: value).prefix(80))")
            }
        }
        // Dump remaining userInfo keys (names only) so we notice unknown codes.
        let extraKeys = ns.userInfo.keys
            .map { "\($0)" }
            .filter { key in !interestingKeys.contains(key) && key != NSUnderlyingErrorKey }
            .sorted()
        if !extraKeys.isEmpty {
            parts.append("userInfoKeys=\(extraKeys.joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    private static func queryKeys(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty
        else { return "-" }
        return items.map(\.name).sorted().joined(separator: ",")
    }

    /// Whether shared cookie jar has any cookie whose domain could match this host.
    /// Does **not** print cookie values.
    private static func cookieJarMatchSummary(for url: URL) -> String {
        guard let host = url.host else { return "host=nil" }
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        if cookies.isEmpty { return "jarEmpty" }
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".")
                ? String(cookie.domain.dropFirst())
                : cookie.domain
            return host == cookie.domain
                || host.hasSuffix(domain)
                || host.contains("bilibili") && cookie.domain.contains("bilibili")
        }
        if matching.isEmpty {
            let sampleDomains = Array(Set(cookies.map(\.domain))).sorted().prefix(6)
            return "none matchHost=\(host) jarDomains=\(sampleDomains.joined(separator: ","))"
        }
        let names = matching.map(\.name).sorted().joined(separator: ",")
        let domains = Array(Set(matching.map(\.domain))).sorted().joined(separator: ",")
        return "match n=\(matching.count) names=\(names) domains=\(domains)"
    }

    private func makePacket(from sample: CMSampleBuffer, track: MediaTrackKind) -> MediaPacket? {
        let ptsCM = CMSampleBufferGetPresentationTimeStamp(sample)
        let durCM = CMSampleBufferGetDuration(sample)
        let pts = CMTIME_IS_NUMERIC(ptsCM) ? max(0, CMTimeGetSeconds(ptsCM)) : 0
        var duration = CMTIME_IS_NUMERIC(durCM) && durCM.isValid && durCM.isNumeric
            ? CMTimeGetSeconds(durCM)
            : 0
        if duration <= 0 {
            duration = track == .video ? 0.04 : 0.02
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        switch track {
        case .video:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                return nil
            }
            return MediaPacket(
                track: .video,
                pts: pts,
                dts: nil,
                duration: duration,
                data: Data(),
                isKeyframe: isKeyframe,
                pixelBuffer: imageBuffer,
                pcmSampleRate: nil,
                pcmChannelCount: nil
            )
        case .audio:
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else {
                return nil
            }
            let length = CMBlockBufferGetDataLength(dataBuffer)
            var data = Data(count: length)
            if length > 0 {
                let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return OSStatus(-12710) }
                    return CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: base
                    )
                }
                if copyStatus != noErr {
                    return nil
                }
            }
            // Prefer duration from PCM size when sample duration was missing.
            let sampleCount = data.count / MemoryLayout<Float>.size
            if sampleCount > 0, sampleCount % pcmChannels == 0, duration <= 0.021 {
                let frames = sampleCount / pcmChannels
                duration = TimeInterval(frames) / pcmSampleRate
            }
            return MediaPacket(
                track: .audio,
                pts: pts,
                dts: nil,
                duration: duration,
                data: data,
                isKeyframe: true,
                pixelBuffer: nil,
                pcmSampleRate: pcmSampleRate,
                pcmChannelCount: pcmChannels
            )
        }
    }

    private func refreshEOF() {
        guard opened else {
            isEOF = true
            return
        }
        let videoDone = videoReader == nil
            || videoReader?.status == .completed
            || videoReader?.status == .failed
            || videoReader?.status == .cancelled
        let audioDone = !hasAudioTrack
            || audioReader == nil
            || audioReader?.status == .completed
            || audioReader?.status == .failed
            || audioReader?.status == .cancelled
        isEOF = videoDone && audioDone
    }

    private func seconds(from time: CMTime) -> TimeInterval {
        guard CMTIME_IS_NUMERIC(time), time.isValid, !time.isIndefinite else { return 0 }
        let s = CMTimeGetSeconds(time)
        return s.isFinite ? max(0, s) : 0
    }
}
