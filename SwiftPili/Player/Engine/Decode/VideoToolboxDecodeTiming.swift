import CoreMedia
import CoreVideo
import Foundation

// Decode-timing observation types used by `VideoToolboxDecoder` (moved out of
// VideoToolboxDecoder.swift unchanged, so the decoder file stays under the
// file-length limit after the preroll batch path was added).

/// Optional warm-only observation. Reads never acquire the native session lock.
protocol MediaVideoDecodeTimingReporting: AnyObject, Sendable {
    func setDecodeTimingEnabled(_ enabled: Bool)
    func decodeTimingSnapshot() -> MediaVideoDecodeTimingSnapshot?
}

struct MediaVideoDecodeTimingSnapshot: Equatable, Sendable {
    var observationID: UInt64 = 0
    var decoderSessionID: UInt64 = 0
    var decodeCalls = 0
    var failures = 0
    var outputFrames = 0
    var body: Duration = .zero
    var lockWait: Duration = .zero
    var integrity: Duration = .zero
    var sampleConstruction: Duration = .zero
    /// Includes synchronous callback collection, not hardware-only time.
    var nativeCall: Duration = .zero
    var postprocess: Duration = .zero
    var firstCall: Duration?
    var firstImageCall: Int?
    var firstImageCallOffset: Duration?

    var logSummary: String {
        func ms(_ duration: Duration) -> String {
            let value = duration.components
            return String(format: "%.3f", Double(value.seconds) * 1_000
                + Double(value.attoseconds) / 1e15)
        }
        return "observation=\(observationID) decoder=\(decoderSessionID) "
            + "calls=\(decodeCalls) failures=\(failures) outputs=\(outputFrames) "
            + "bodyMs=\(ms(body)) lockMs=\(ms(lockWait)) integrityMs=\(ms(integrity)) "
            + "sampleMs=\(ms(sampleConstruction)) nativeMs=\(ms(nativeCall)) "
            + "postMs=\(ms(postprocess)) firstCallMs=\(firstCall.map(ms) ?? "n/a") "
            + "firstImageCall=\(firstImageCall.map(String.init) ?? "n/a") "
            + "firstImageOffsetMs=\(firstImageCallOffset.map(ms) ?? "n/a")"
    }

    mutating func append(_ call: Self) {
        decodeCalls += 1
        failures += call.failures
        outputFrames += call.outputFrames
        body += call.body
        lockWait += call.lockWait
        integrity += call.integrity
        sampleConstruction += call.sampleConstruction
        nativeCall += call.nativeCall
        postprocess += call.postprocess
        if firstCall == nil { firstCall = call.body }
        if firstImageCall == nil, let offset = call.firstImageCallOffset {
            firstImageCall = decodeCalls
            firstImageCallOffset = offset
        }
    }
}

/// Short scalar-only critical sections: no native API, callback, logging or await.
/// Snapshot contention means unavailable, never a wait on a stuck decoder.
final class MediaVideoDecodeTimingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var value = MediaVideoDecodeTimingSnapshot()

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            guard self.enabled != enabled else { return }
            self.enabled = enabled
            if enabled {
                let next = value.observationID &+ 1
                value = MediaVideoDecodeTimingSnapshot(observationID: next)
            }
        }
    }

    func observationID() -> UInt64? {
        lock.withLock { enabled ? value.observationID : nil }
    }

    func snapshot() -> MediaVideoDecodeTimingSnapshot? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return enabled ? value : nil
    }

    func record(_ call: MediaVideoDecodeTimingSnapshot) {
        lock.withLock {
            guard enabled, call.observationID == value.observationID else { return }
            if value.decodeCalls == 0 {
                value.decoderSessionID = call.decoderSessionID
            }
            guard value.decoderSessionID == call.decoderSessionID else { return }
            value.append(call)
        }
    }
}

struct VideoToolboxDecodeTimingTrace {
    enum Phase { case lockWait, integrity, sampleConstruction, nativeCall, postprocess }
    let started = ContinuousClock.now
    private var last: ContinuousClock.Instant
    private var phase: Phase = .lockWait
    var value: MediaVideoDecodeTimingSnapshot

    init(observationID: UInt64) {
        last = started
        value = MediaVideoDecodeTimingSnapshot(observationID: observationID, failures: 1)
    }

    mutating func advance(to next: Phase, at now: ContinuousClock.Instant = .now) {
        let elapsed = now - last
        switch phase {
        case .lockWait: value.lockWait += elapsed
        case .integrity: value.integrity += elapsed
        case .sampleConstruction: value.sampleConstruction += elapsed
        case .nativeCall: value.nativeCall += elapsed
        case .postprocess: value.postprocess += elapsed
        }
        last = now
        phase = next
    }

    mutating func finish() -> MediaVideoDecodeTimingSnapshot {
        let now = ContinuousClock.now
        advance(to: .postprocess, at: now)
        value.body = now - started
        return value
    }
}

struct VideoToolboxOutputRecord {
    let event: VideoToolboxTimingOutputEvent
    let imageBuffer: CVPixelBuffer?
    /// Keep the native values for the opt-in audit without making Core Media a
    /// dependency of the pure timing policy.
    let callbackPTS: CMTime
    let callbackDuration: CMTime
}


extension VideoToolboxOutputRecord {
    /// The callback's native time is retained before scalar conversion. If it
    /// repeats the submitted native representation, the content interval is
    /// unchanged; a genuinely changed callback boundary is authoritative.
    func displayCoverage(packet: MediaPacket, resolution: VideoToolboxTimingResolution,
                         submitted: CMSampleTimingInfo) -> MediaDisplayLease? {
        guard let input = packet.displayCoverage?.interval else { return nil }
        let lower: MediaDisplayTime?
        let duration: MediaDisplayTime?
        switch resolution {
        case .callback:
            lower = callbackPTS == submitted.presentationTimeStamp ? input.lower : Self.time(callbackPTS)
            if callbackDuration == submitted.duration, callbackPTS == submitted.presentationTimeStamp {
                return packet.displayCoverage?.producing(input)
            }
            duration = Self.time(callbackDuration)
        case .oneToOneInputFallback:
            lower = Self.time(callbackPTS) ?? input.lower
            duration = Self.time(callbackDuration)
            if duration == nil, lower == input.lower {
                return packet.displayCoverage?.producing(input)
            }
        case .unknown:
            return nil
        }
        return packet.displayCoverage?.producing(MediaDisplayInterval(lower, duration.flatMap { lower?.adding($0) }))
    }

    private static func time(_ value: CMTime) -> MediaDisplayTime? {
        guard value.isValid, value.isNumeric, value.epoch == 0 else { return nil }
        return MediaDisplayTime(value.value, scale: Int64(value.timescale))
    }
}
