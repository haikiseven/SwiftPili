import Foundation
import UIKit

struct NetworkSpeedSamplingFence: Equatable, Sendable {
    let streamGeneration: Int

    func accepts(currentStreamGeneration: Int) -> Bool {
        streamGeneration == currentStreamGeneration
    }
}

extension PlayerViewModel {

    // MARK: - Network speed sampling

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
        let info = backend.dynamicInfo
        let reading = PlaybackByteRateSampler.Reading(
            networkBytes: info?.networkBytesReceived ?? 0,
            pipelineBytes: info?.bytesRead ?? 0
        )
        publishNetworkSpeedSample(reading, at: CACurrentMediaTime())
    }

    func publishNetworkSpeedSample(_ reading: PlaybackByteRateSampler.Reading, at now: TimeInterval) {
        guard let rates = byteRateSampler.sample(reading, at: now) else { return }
        if rates.pipelineAdvanced { lastBytesAdvanceAt = now }
        pipelineGoodput = rates.goodput
        if let network = rates.network, stats.networkSpeed != network {
            stats.networkSpeed = network
        }
        evaluateDeliveryHealth(goodput: rates.goodput)
        pushFreezeWatchdogSample()
    }

    private func pushFreezeWatchdogSample() {
        FreezeWatchdog.notePlayer(FreezePlayerSample(
            streamID: "\(mode)#\(playerGeneration)",
            mode: "\(mode)",
            engine: backendKind.shortLabel,
            state: isBuffering ? "buffering" : (isPlaying ? "playing" : "paused"),
            expectsProgress: isPlaying
                && !isBuffering
                && pendingSeekTarget == nil
                && !currentPlaybackTerminalState.isTerminal,
            mediaTime: mediaTime,
            displayTime: displayTime,
            fps: stats.fps,
            clockSource: backendKind == .demandPaced ? "audio-drain" : "libvlc-internal",
            runway: backend.bufferedContentAhead,
            videoRunway: backend.videoDeliveryRunway,
            available: bufferedTime,
            networkKBs: Int(stats.networkSpeed / 1024),
            goodputKBs: Int(pipelineGoodput / 1024),
            quality: "\(currentQuality)",
            host: stats.videoHost,
            recovery: budget.summary
        ))
    }

    // MARK: - Smart CDN delivery health (phase 1)

    private func evaluateDeliveryHealth(goodput: Double) {
        guard let runway = backend.bufferedContentAhead, runway.isFinite else {
            unhealthySamples = 0
            return
        }
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
        guard bufferedTime < duration - 5 else {
            unhealthySamples = 0
            return
        }
        guard CACurrentMediaTime() - lastStreamStartAt > 10 else {
            unhealthySamples = 0
            return
        }
        let requiredBps = Double(streamNominalBitrate) / 8 * Double(max(playbackRate, 1))
        guard requiredBps > 0 else {
            unhealthySamples = 0
            return
        }
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
        scheduleCDNSwitch(reason: "sustained under-delivery")
    }
}
