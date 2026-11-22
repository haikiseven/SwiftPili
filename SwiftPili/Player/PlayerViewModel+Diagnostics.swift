import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func stressTick() {
        // isCapturing, not debugLogging: a Playback Report capture with debug
        // logging off must still carry the [stress] line (buf=/avail=/fps).
        guard PlayerLog.isCapturing else { return }
        stressLogTick += 1
        guard stressLogTick % 2 == 0 else { return }
        // Stress t= is media truth; show display separately when near-EOF
        // presentation is armed so logs do not look like media advanced.
        var line = "[stress] \(mode)"
        line += " st=\(isBuffering ? "buffering" : (isPlaying ? "playing" : "paused"))\("")"
        line += " t=\(String(format: "%.1f", mediaTime))/\(String(format: "%.0f", duration))"
        if abs(displayTime - mediaTime) > 0.2 {
            line += " disp=\(String(format: "%.1f", displayTime))"
        }
        // Measured delivery runway or `n/a` — NOT `bufferedTime - mediaTime`,
        // which is the availability horizon (a whole local file, once it opens).
        line += " buf=\(runwayLogText)"
        line += " vbuf=\(videoRunwayLogText)"
        line += " avail=\(String(format: "%.1f", bufferedTime))"
        line += bufferDisplayLogText()
        line += " fps=\(String(format: "%.1f", stats.fps))"
        line += " drop=\(stats.droppedFrames)(\(String(format: "%+.1f", stats.dropRate))/s)"
        line += " br=\(Int(Double(stats.bitrate) / 1000))kbps"
        // `net=` = the displayed wire rate; `gp=` = pipeline goodput (the
        // delivery-health input). They diverge under multi-connection
        // read-ahead and on store-fed stretches.
        line += " net=\(Int(stats.networkSpeed / 1024))KB/s"
        line += " gp=\(Int(pipelineGoodput / 1024))KB/s"
        line += " q=\(currentQuality) rate=\(String(format: "%.2f", playbackRate))"
        line += " res=\(stats.resolution)"
        // VLC handles DASH A/V sync internally — no drift metric available
        line += " host=\(stats.videoHost)"
        line += " rec[\(budget.summary)]"
        if let error { line += " err=\(error)" }
        PlayerLog.log(line)
    }

    /// Formats only the last admitted UI sample. Missing/retired observations
    /// stay explicit; logging must not scan the evidence book or refresh UI.
    private func bufferDisplayLogText() -> String {
        let displayed = Self.bufferDisplayEndpointText(displayedBufferedTime)
        guard let observation = bufferedDisplayDiagnostic else { return " bufUI=\(displayed) bufObs=none" }
        guard observation.backendIdentity == ObjectIdentifier(backend),
              observation.runtimeGeneration == backend.runtimeGeneration,
              observation.loadGeneration == loadGeneration,
              observation.ownerLeaseGeneration == ownerLeaseGeneration else {
            return " bufUI=\(displayed) bufObs=stale"
        }
        let age = max(0, CACurrentMediaTime() - observation.sampledAt) * 1000
        var text = " bufUI=\(displayed) bufObs=sample bufAgeMs=\(String(format: "%.0f", age))"
        text += " bufRaw=\(Self.bufferDisplayEndpointText(observation.rawEndpoint))"
        guard let sample = observation.display else { return text + " bufPath=raw" }
        text += " bufPath=\(sample.evidence == nil ? "established" : "evidence")"
        text += " bufAt=\(Self.bufferDisplayEndpointText(sample.position))"
        text += " bufOut=\(Self.bufferDisplayEndpointText(sample.bufferedThrough))"
        text += " bufTracks=\(sample.videoPresent ? "v" : "-")\(sample.audioPresent ? "a" : "-")"
        text += " bufWarm=\(sample.videoWarmSuspended ? 1 : 0)"
        text += " bufVE=\(Self.bufferDisplayEndpointText(sample.evidence?.video))"
        text += " bufAE=\(Self.bufferDisplayEndpointText(sample.evidence?.audio))"
        text += " bufV=\(Self.bufferDisplayEndpointText(sample.resolved.video))"
        text += " bufA=\(Self.bufferDisplayEndpointText(sample.resolved.audio))"
        return text + audioDisplayJoinLogText(sample.evidence?.audioJoin)
    }

    private func audioDisplayJoinLogText(_ join: MediaAudioDisplayJoin?) -> String {
        guard let join else { return "" }
        let pcm = Self.exactBufferTimeText(join.pcmEnd)
        let source = Self.exactBufferTimeText(join.sourceEnd)
        let append = join.appendEnd.map { String(format: "%.9f", $0) } ?? "-"
        return " bufAJoin=\(join.result.rawValue) bufAPCM=\(pcm) bufASrc=\(source) bufAAppend=\(append)"
    }

    private static func exactBufferTimeText(_ time: MediaDisplayTime?) -> String {
        guard let time else { return "-" }
        return "\(time.value)/\(time.scale)"
    }

    private static func bufferDisplayEndpointText(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.3f", value)
    }

    func updateDynamicStats() {
        let videoTrack = backend.videoTracks().first
        if let size = videoTrack?.naturalSize, size.width > 0, size.height > 0 {
            // Keep portrait propagation independent from the optional
            // throughput snapshot. Demand can expose geometry before its
            // dynamic stats are populated.
            self.applyVideoGeometry(size)
        }
        guard let info = backend.dynamicInfo else { return }
        var s = stats
        s.fps = info.displayFPS
        let drops = Int(info.droppedVideoFrameCount + info.droppedVideoPacketCount)
        s.droppedFrames = drops
        let now = CACurrentMediaTime()
        if let last = lastDropSample, drops >= last.count, now - last.at > 0.5 {
            s.dropRate = Double(drops - last.count) / (now - last.at)
        } else if lastDropSample == nil || drops < lastDropSample!.count {
            s.dropRate = 0
        }
        if lastDropSample == nil || now - lastDropSample!.at > 0.5 || drops < lastDropSample!.count {
            lastDropSample = (drops, now)
        }
        if let size = videoTrack?.naturalSize {
            if size.width > 0, size.height > 0 {
                if size != cachedResolutionSize {
                    cachedResolutionSize = size
                    s.resolution = "\(Int(size.width))×\(Int(size.height))"
                }
            }
        }
        s.bufferHealth = pendingBufferHealth
        s.videoEnhancement = currentVideoEnhancementTelemetry()
        if s != stats { stats = s }
    }
}

extension PlayerViewModel {

    func markDemandBackgroundStage(_ stage: String, startsTransition: Bool = false) {
        if startsTransition {
            demandBackgroundStageTape = DemandBackgroundStageTape(base: .now)
        }
        guard demandBackgroundStageTape != nil else { return }
        demandBackgroundStageTape?.mark(stage)
        guard stage == "bgDone" else { return }
        if let summary = demandBackgroundStageTape?.summary {
            PlayerLog.log(
                "[Lifecycle] background stages \(summary) " +
                "state=\(Self.applicationStateLabel)"
            )
        }
        demandBackgroundStageTape = nil
    }

    /// Was the main thread COMPUTING during the visible transition, or merely not scheduled?
    nonisolated static func probeMainThreadAcrossTransition() {
        // The Mach walks are diagnostic work, including report-only capture.
        guard PlayerLog.isCapturing else { return }
        Task.detached(priority: .userInitiated) {
            guard PlayerLog.isCapturing else { return }
            var running = 0
            var waiting = 0
            var other = 0
            var peakUsage = 0.0
            let deadline = ContinuousClock.now + .seconds(2)
            let postedAt = ContinuousClock.now
            nonisolated(unsafe) var hopMilliseconds = -1
            DispatchQueue.main.async {
                let elapsed = ContinuousClock.now - postedAt
                hopMilliseconds = Int(elapsed.components.seconds * 1000
                    + elapsed.components.attoseconds / 1_000_000_000_000_000)
            }
            while ContinuousClock.now < deadline {
                guard PlayerLog.isCapturing else { return }
                let sample = PowerProfiler.sampleSystem()
                if let main = sample.threads.first(where: { $0.isMain }) {
                    peakUsage = max(peakUsage, main.usage)
                    switch main.runStateLabel {
                    case "running": running += 1
                    case "waiting": waiting += 1
                    default: other += 1
                    }
                }
                guard PlayerLog.isCapturing else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            PlayerLog.log(
                "[Lifecycle] background probe mainRunning=\(running) " +
                "mainWaiting=\(waiting) mainOther=\(other) " +
                "mainCpuPeak=\(Int(peakUsage))% " +
                "mainQueueHop=\(hopMilliseconds)ms"
            )
        }
    }

    /// Record one stage of the in-flight foreground transition.
    func markDemandForegroundStage(
        _ stage: String,
        startsTransition: Bool = false,
        fence: DemandPresentationFence
    ) {
        // A tape is only closed by `proof` or `failed`.
        let key = DemandStageSessionKey(fence)
        // A tape whose session is not this one measures another transition. An
        // activation is entitled to its own tape, so it restarts rather than
        // being dropped along with the stale one.
        let crossSession = demandForegroundStageTape?.session
            .map { $0 != key } ?? false
        if startsTransition
            || (stage == "active"
                && (crossSession
                    || demandForegroundStageTape?.hasMarkedActivation == true)) {
            demandForegroundStageTape = DemandForegroundStageTape(base: .now)
        }
        guard var tape = demandForegroundStageTape else { return }
        // Any other cross-session stage: the tape's base belongs to a different session's transition, so
        // nothing measured against it can be reported truthfully — and closing it here is exactly how a
        // `proof=13741ms` was emitted for a session half a second old.
        if let bound = tape.session, bound != key {
            demandForegroundStageTape = nil
            return
        }
        tape.session = key
        tape.mark(stage)
        demandForegroundStageTape = tape
        guard stage == "proof" || stage == "failed" else { return }
        PlayerLog.log("[PathA][continuation] foreground stages \(tape.summary)")
        demandForegroundStageTape = nil
    }

    /// Close an open foreground tape without emitting it.
    func discardDemandForegroundStageTape() {
        demandForegroundStageTape = nil
    }
}
