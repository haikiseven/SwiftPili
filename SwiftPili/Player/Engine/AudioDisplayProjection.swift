enum AudioDisplayProjection {
    static func endpoint(
        at position: MediaDisplayTime, source: [MediaDisplayInterval], direct: DirectDisplayEvidence.Snapshot,
        hasSourceSampleStartingAt: (MediaDisplayTime) -> Bool
    ) -> (end: Double?, join: MediaAudioDisplayJoin?) {
        guard let pcmEnd = MediaDisplayInterval.connectedEnd(at: position, in: direct.acceptedPCM) else {
            let pendingEnd = MediaDisplayInterval.connectedEnd(at: position, in: direct.pendingPCM)
            if let sourceEnd = MediaDisplayInterval.connectedEnd(at: position, in: source) {
                return (max(sourceEnd, pendingEnd ?? sourceEnd).seconds, nil)
            }
            return (pendingEnd?.seconds, nil)
        }
        let handoff = direct.handoff(at: pcmEnd)
        func observed(_ end: Double, _ result: MediaAudioDisplayJoin.Result) -> (Double, MediaAudioDisplayJoin) {
            (end, MediaAudioDisplayJoin(
                pcmEnd: pcmEnd, sourceEnd: handoff?.sourceEnd,
                appendEnd: handoff?.acceptedTail.timelineEnd, result: result
            ))
        }
        let boundary = handoff?.sourceEnd ?? pcmEnd
        if let handoff, !handoff.acceptedTail.canContinue(at: boundary.seconds) {
            return observed(pcmEnd.seconds, .appendWouldDiscontinue)
        }
        guard hasSourceSampleStartingAt(boundary),
              let available = MediaDisplayInterval.connectedEnd(at: boundary, in: source) else {
            return observed(pcmEnd.seconds, .successorUnavailable)
        }
        return observed(pcmEnd.seconds + (available.seconds - boundary.seconds), .joined)
    }
}
