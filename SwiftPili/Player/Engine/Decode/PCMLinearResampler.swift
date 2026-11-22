import Foundation

struct PCMLinearResampler: Sendable {
    struct Output: Sendable {
        let pcm: [Float]
        let verifiedSourceEnd: MediaDisplayTime?

        static let empty = Output(pcm: [], verifiedSourceEnd: nil)
    }

    let inputSampleRate: Double
    let outputSampleRate: Double
    let channelCount: Int

    private var buffer: [Float] = []
    private var position: Double = 0
    private struct InputSpan: Sendable {
        var frames: Range<Int>
        let track: UUID
        let interval: MediaDisplayInterval
    }

    private var verifiedInput: [InputSpan] = []

    init(inputSampleRate: Double, outputSampleRate: Double, channelCount: Int) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channelCount = channelCount
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        position = 0
        verifiedInput.removeAll(keepingCapacity: true)
    }

    mutating func process(
        _ pcm: [Float], frameCount: Int, verifiedSource: MediaDisplayLease? = nil
    ) -> Output {
        guard frameCount > 0,
              channelCount > 0,
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              outputSampleRate.isFinite,
              outputSampleRate > 0
        else { return .empty }

        let sampleCount = min(frameCount * channelCount, pcm.count)
        guard sampleCount >= channelCount else { return .empty }

        if abs(inputSampleRate - outputSampleRate) <= 0.5 {
            return Output(pcm: Array(pcm.prefix(sampleCount)), verifiedSourceEnd: nil)
        }

        if let verifiedSource, verifiedSource.isCurrent, let interval = verifiedSource.interval,
           sampleCount == frameCount * channelCount {
            let start = buffer.count / channelCount
            verifiedInput.append(InputSpan(
                frames: start..<(start + frameCount), track: verifiedSource.trackIdentity, interval: interval
            ))
        }
        buffer.append(contentsOf: pcm.prefix(sampleCount))

        let step = inputSampleRate / outputSampleRate
        let availableFrames = buffer.count / channelCount
        guard step.isFinite, step > 0, availableFrames > 1 else { return .empty }

        var output: [Float] = []
        output.reserveCapacity(Int(ceil(Double(frameCount) / step)) + 2)

        let firstSupportFrame = Int(position.rounded(.towardZero))
        var supportEnd = firstSupportFrame
        while Int(position.rounded(.towardZero)) + 1 < availableFrames {
            let firstFrame = Int(position.rounded(.towardZero))
            let fraction = Float(position - Double(firstFrame))
            let firstSample = firstFrame * channelCount
            let secondSample = min(firstFrame + 1, availableFrames - 1) * channelCount

            for channel in 0..<channelCount {
                let first = buffer[firstSample + channel]
                let second = buffer[secondSample + channel]
                output.append(first + (second - first) * fraction)
            }
            supportEnd = firstFrame + 2
            position += step
        }

        let verifiedSourceEnd: MediaDisplayTime? = verifiedSource.flatMap { source in
            guard !output.isEmpty, supportEnd == availableFrames else { return nil }
            return verifiedEnd(in: firstSupportFrame..<supportEnd, source: source)
        }
        discardConsumedInput(availableFrames: availableFrames)
        return Output(pcm: output, verifiedSourceEnd: verifiedSourceEnd)
    }

    private func verifiedEnd(in inputFrames: Range<Int>, source: MediaDisplayLease) -> MediaDisplayTime? {
        guard !inputFrames.isEmpty, source.isCurrent, let expectedEnd = source.interval?.upper else { return nil }
        var nextFrame = inputFrames.lowerBound
        var previousEnd: MediaDisplayTime?
        for span in verifiedInput where span.frames.upperBound > nextFrame {
            let upper = min(inputFrames.upperBound, span.frames.upperBound)
            guard span.frames.lowerBound <= nextFrame, upper > nextFrame, span.track == source.trackIdentity,
                  let start = span.interval.lower.adding(
                      frames: nextFrame - span.frames.lowerBound, sampleRate: inputSampleRate
                  ), previousEnd.map({ $0 == start }) ?? true,
                  let end = start.adding(frames: upper - nextFrame, sampleRate: inputSampleRate)
            else { return nil }
            if upper == inputFrames.upperBound { return end == expectedEnd ? end : nil }
            nextFrame = upper
            previousEnd = end
        }
        return nil
    }

    private mutating func discardConsumedInput(availableFrames: Int) {
        let discardFrames = min(
            max(0, availableFrames - 2),
            max(0, Int(position.rounded(.towardZero)) - 1)
        )
        guard discardFrames > 0 else { return }
        verifiedInput.removeAll { $0.frames.upperBound <= discardFrames }
        for index in verifiedInput.indices {
            let frames = verifiedInput[index].frames
            verifiedInput[index].frames = (frames.lowerBound - discardFrames)..<(frames.upperBound - discardFrames)
        }
        buffer.removeFirst(discardFrames * channelCount)
        position -= Double(discardFrames)
    }
}
