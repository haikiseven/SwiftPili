import Foundation

/// One 1Hz sample's verdict for the Smart CDN delivery-health monitor
/// (`PlayerViewModel.evaluateDeliveryHealth`), split out so the rule itself is
/// testable without a live player. The stand-down guards (mode, playing,
/// startup, near-EOF, an unmeasured runway) stay in the monitor; this is only
/// the "is this second unhealthy" arithmetic, unchanged from where it lived.
///
/// Its two inputs and where they come from — the reason a stretch played from
/// the byte store (media cache P1) can never read as under-delivery:
/// - `goodput` is Δ`dynamicInfo.bytesRead` per second. On Demand that counter
///   is `MediaEngineSession.bytesRead`, the payload bytes of every packet the
///   pipeline INGESTED — not the source's network counter. A packet demuxed
///   from store-held bytes counts exactly like one from the network, so
///   delivery is measured as content reaching the pipeline, whatever carried it.
/// - `runway` is `bufferedContentAhead` = the session's binding
///   `deliveryRunway`, which includes the whole fragments the store holds past
///   the demuxer. While the store can feed the pump, that alone keeps the
///   runway above `runwayFloor`, so the sample is healthy regardless of goodput.
///
/// Once the held content runs out, the next bytes need the network and the
/// monitor judges the host again, as it should.
enum DeliveryHealthSample {
    enum Verdict: Equatable {
        case healthy
        case unhealthy(severe: Bool)
    }

    /// ×1.2 over the nominal demand covers container overhead and jitter.
    static let demandMargin = 1.2
    static let runwayCeiling: TimeInterval = 20
    static let runwayFloor: TimeInterval = 3
    static let recoveryTolerance: TimeInterval = 0.5

    static func verdict(
        goodput: Double,
        requiredBps: Double,
        runway: TimeInterval,
        lastRunway: TimeInterval
    ) -> Verdict {
        // All three at once, for consecutive samples: delivery below
        // demand, runway short, runway not recovering. A slow edge whose
        // runway still GROWS is keeping up; leave it alone.
        guard goodput < requiredBps * demandMargin,
              runway < runwayCeiling,
              runway <= lastRunway + recoveryTolerance else { return .healthy }
        // Runway floor: a demand-paced source downloads in bursts — between
        // bursts the 1Hz speed sampler reads 0KB/s even while fps=60 and the
        // runway is healthy. A runway >= 3s means multiple seconds of content are
        // banked and no stall is imminent, regardless of the instantaneous
        // goodput. The caller resets instead of incrementing, so transient dips
        // between bursts never accumulate toward a false-positive switch.
        guard runway < runwayFloor else { return .healthy }
        // Severe = goodput below REAL-TIME demand (not just under the 1.2
        // margin): the runway is actively draining, not merely failing to
        // grow. Those hosts — the ones that stall 4K — earn a faster switch
        // (3s vs 5s), banking runway the reopen then needs. A marginal edge
        // that's basically keeping up still waits the full 5s, so this adds
        // no new false positives.
        return .unhealthy(severe: goodput < requiredBps)
    }
}
