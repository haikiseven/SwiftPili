import Foundation
import UIKit

// Why it must not come back is in PLAYER_DESIGN.md §2.5; the short form sits at the `.buffering` state edge in
// PlayerViewModel.swift, which is the site where it would be re-added.

/// Identity of the stream/load a network sampler belongs to.
struct NetworkSpeedSamplingFence: Equatable, Sendable {
    let streamGeneration: Int

    func accepts(currentStreamGeneration: Int) -> Bool {
        streamGeneration == currentStreamGeneration
    }
}

extension PlayerViewModel {

    // MARK: - Network speed sampling

    /// 1Hz byte sampler — runs for the stream's lifetime (unlike onPlay ticks it keeps reporting DURING stalls,
    /// which is when the number matters most).
    func startSpeedSampling() {
        speedSampleTask?.cancel()
        byteRateSampler.reset()
        pipelineGoodput = 0
        if stats.networkSpeed != 0 { stats.networkSpeed = 0 }
        let fence = NetworkSpeedSamplingFence(streamGeneration: loadGeneration)
        speedSampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      fence.accepts(currentStreamGeneration: self.loadGeneration) else { return }
                self.sampleMultiConnectionDisplay()
                self.sampleNetworkSpeed()
                self.stressTick()
            }
        }
    }

    private func sampleNetworkSpeed() {
        PowerProfiler.tick(.netSampler)
        // No dynamic info → both counters read 0, exactly as before the split.
        let info = backend.dynamicInfo
        let reading = PlaybackByteRateSampler.Reading(
            networkBytes: info?.networkBytesReceived ?? 0,
            pipelineBytes: info?.bytesRead ?? 0
        )
        publishNetworkSpeedSample(reading, at: CACurrentMediaTime())
    }

    /// Apply one monotonic transport reading without making sampler bookkeeping
    /// observable. Health/liveness retain their independent pipeline input.
    func publishNetworkSpeedSample(_ reading: PlaybackByteRateSampler.Reading, at now: TimeInterval) {
        // Counters can go backwards across player swaps — that sample is skipped.
        guard let rates = byteRateSampler.sample(reading, at: now) else { return }
        // Window-based liveness: any PIPELINE advance keeps `dataFlowing` alive for `dataFlowWindow`, so
        // bursty (Path A) fetch gaps are not misread as starvation while genuine no-data still ages out.
        if rates.pipelineAdvanced { lastBytesAdvanceAt = now }
        pipelineGoodput = rates.goodput
        // Write only on CHANGE: @Observable invalidates on every write, and stats is a struct property, so
        // touching one field re-renders every view reading ANY stats field.
        if let network = rates.network, stats.networkSpeed != network {
            stats.networkSpeed = network
        }
        evaluateDeliveryHealth(goodput: rates.goodput)
        pushFreezeWatchdogSample()
    }

    /// This is the ONLY way the freeze watchdog learns anything about playback: it runs on its own queue, and a
    /// freeze report that had to hop to the main actor for the media clock would be waiting on the very thread
    /// it is diagnosing.
    private func pushFreezeWatchdogSample() {
        FreezeWatchdog.notePlayer(FreezePlayerSample(
            // Generation, not aid/cid: it changes on every open including a
            // quality switch and an in-place CDN swap, which is exactly when the
            // movement anchors must start over.
            streamID: "\(mode)#\(playerGeneration)",
            mode: "\(mode)",
            engine: backendKind.shortLabel,
            state: isBuffering ? "buffering" : (isPlaying ? "playing" : "paused"),
            // Same exclusion the liveness evaluator makes in `watchdogStandDownReason`.
            expectsProgress: isPlaying
                && !isBuffering
                && pendingSeekTarget == nil
                && !currentPlaybackTerminalState.isTerminal,
            mediaTime: mediaTime,
            displayTime: displayTime,
            fps: stats.fps,
            clockSource: backendKind == .demandPaced ? "audio-drain" : "libvlc-internal",
            // nil = unmeasured, never zero — libVLC publishes no runway at all
            // and resolving that to 0 would claim an empty buffer.
            runway: backend.bufferedContentAhead,
            videoRunway: backend.videoDeliveryRunway,
            available: bufferedTime,
            networkKBs: Int(stats.networkSpeed / 1024),
            // The liveness input — pipeline goodput, unchanged from before the
            // display moved to the wire rate.
            goodputKBs: Int(pipelineGoodput / 1024),
            quality: "\(currentQuality)",
            host: stats.videoHost,
            recovery: budget.summary
        ))
    }

    // MARK: - Smart CDN delivery health (phase 1)

    /// Delivery health is measured where the problem shows first — goodput vs. demand plus the buffered
    /// runway's trend — and a sustained deficit switches CDN in place BEFORE the stall that the reactive paths
    /// only catch after the buffer has already run dry.
    private func evaluateDeliveryHealth(goodput: Double) {
        guard let runway = backend.bufferedContentAhead, runway.isFinite else {
            unhealthySamples = 0
            return
        }
        // Below the guard it went stale, and the first sample after a resume compared against a runway from an
        // arbitrarily older second.
        defer { lastRunway = runway }
        guard mode.usesOnlineVODServices, isPlaying, !isBuffering, !streamRecoveryOwnsWork,
              pendingSeekTarget == nil,
              !currentPlaybackTerminalState.isTerminal,
              canAutoRevive, error == nil,
              duration > 0,
              UIApplication.shared.applicationState == .active else {
            unhealthySamples = 0
            return
        }
        // Buffered to (nearly) the end: nothing left to fetch — a low
        // goodput is expected and healthy.
        guard bufferedTime < duration - 5 else {
            unhealthySamples = 0
            return
        }
        // Startup filling is not under-delivery; the liveness ladder owns a
        // stream that never fills at all. (This said "the buffer timeout's
        // domain" — that timer was deleted; nothing replaced it here.)
        guard CACurrentMediaTime() - lastStreamStartAt > 10 else {
            unhealthySamples = 0
            return
        }
        // Demand at the current speed (bitrate is bits/s); ×1.2 covers container overhead and sampling jitter.
        let requiredBps = Double(streamNominalBitrate) / 8 * Double(max(playbackRate, 1))
        guard requiredBps > 0 else {
            unhealthySamples = 0
            return
        }
        // The per-second rule, and why a stretch played from the byte store
        // cannot trip it, live in `DeliveryHealthSample`.
        guard case .unhealthy(let severe) = DeliveryHealthSample.verdict(
            goodput: goodput,
            requiredBps: requiredBps,
            runway: runway,
            lastRunway: lastRunway
        ) else {
            unhealthySamples = 0
            return
        }
        unhealthySamples += 1
        let confirmSamples = severe ? 3 : 5
        // `video=` names the track the binding runway came from — a switch decision that cannot be traced back
        // to which queue was short is not reviewable after the fact, which is how the audio-dominated metric
        // survived as long as it did.
        let videoRunwayText = backend.videoDeliveryRunway
            .map { String(format: "%.1f", max(0, $0)) + "s" } ?? "n/a"
        PlayerLog.log("[SmartCDN] delivery health: goodput=\(Int(goodput / 1024))KB/s need≈\(Int(requiredBps * 1.2 / 1024))KB/s runway=\(String(format: "%.1f", runway))s video=\(videoRunwayText)\(severe ? " SEVERE" : "") (\(unhealthySamples)/\(confirmSamples))")
        guard unhealthySamples >= confirmSamples else { return }
        unhealthySamples = 0
        guard currentAid != nil, currentCid != nil else { return }
        guard Self.cdnFallbackEnabled else {
            PlayerLog.log("[SmartCDN] delivery still unhealthy — automatic CDN fallback is disabled")
            return
        }
        guard budget.canSwitchCDN else {
            PlayerLog.log("[SmartCDN] delivery still unhealthy — no hosts left to try; recovery that isn't a host swap owns it from here")
            return
        }
        PlayerLog.log("[SmartCDN] 🔁 proactive switch: edge can't sustain the stream — switching CDN at t=\(String(format: "%.1f", mediaTime)) before the stall")
        // The common scheduling seam captures this exact observed source.
        scheduleCDNSwitch(reason: "sustained under-delivery")
    }
}
