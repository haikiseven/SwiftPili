import CoreMedia
import CoreVideo
import Foundation
import Synchronization

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

final class MediaVideoDecodeTimingStore: @unchecked Sendable {
    private let enabledAtomic = Atomic<Bool>(false)
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
            enabledAtomic.store(enabled, ordering: .releasing)
        }
    }

    func observationID() -> UInt64? {
        guard enabledAtomic.load(ordering: .acquiring) else { return nil }
        return lock.withLock { enabled ? value.observationID : nil }
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
