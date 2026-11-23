import Foundation

struct PCMLinearResampler: Sendable {
    private final class PolyphaseKernel: Sendable {
        static let taps = 32
        static let halfTaps = taps / 2
        static let phaseCount = 512

        // (phaseCount + 1) rows of `taps` floats for linear phase interpolation
        let weights: [Float]

        init(step: Double) {
            let taps = Self.taps
            let halfTaps = Self.halfTaps
            let phaseCount = Self.phaseCount
            let cutoff = min(0.94, 0.94 / max(1.0, step))
            let halfSpan = Double(halfTaps)
            var table = [Float](repeating: 0, count: (phaseCount + 1) * taps)
            var row = [Double](repeating: 0, count: taps)

            for phaseIndex in 0...phaseCount {
                let frac = Double(phaseIndex) / Double(phaseCount)
                var sum = 0.0
                for tap in 0..<taps {
                    let x = Double(tap - (halfTaps - 1)) - frac
                    let u = (x + halfSpan) / (2.0 * halfSpan)
                    let window: Double
                    if u <= 0 || u >= 1 {
                        window = 0
                    } else {
                        // 4-term Blackman-Harris window (~-92 dB sidelobes)
                        let twopi = 2.0 * Double.pi * u
                        window = 0.35875
                            - 0.48829 * cos(twopi)
                            + 0.14128 * cos(2.0 * twopi)
                            - 0.01168 * cos(3.0 * twopi)
                    }
                    let sincArg = x * cutoff
                    let sinc = abs(sincArg) < 1e-12
                        ? 1.0
                        : sin(Double.pi * sincArg) / (Double.pi * sincArg)
                    let weight = sinc * window
                    row[tap] = weight
                    sum += weight
                }
                let invSum = sum != 0 ? 1.0 / sum : 1.0
                let rowBase = phaseIndex * taps
                for tap in 0..<taps {
                    table[rowBase + tap] = Float(row[tap] * invSum)
                }
            }
            self.weights = table
        }
    }

    let inputSampleRate: Double
    let outputSampleRate: Double
    let channelCount: Int

    private let kernel: PolyphaseKernel?
    private let initialPadFrames: Int
    private var initialPadRemaining: Int
    private var buffer: [Float]
    private var position: Double

    init(inputSampleRate: Double, outputSampleRate: Double, channelCount: Int) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channelCount = channelCount
        if channelCount > 0,
           inputSampleRate.isFinite, inputSampleRate > 0,
           outputSampleRate.isFinite, outputSampleRate > 0,
           abs(inputSampleRate - outputSampleRate) > 0.5 {
            let step = inputSampleRate / outputSampleRate
            let pad = PolyphaseKernel.halfTaps - 1
            self.kernel = PolyphaseKernel(step: step)
            self.initialPadFrames = pad
            self.initialPadRemaining = pad
            self.buffer = [Float](repeating: 0, count: pad * channelCount)
            self.position = Double(pad)
        } else {
            self.kernel = nil
            self.initialPadFrames = 0
            self.initialPadRemaining = 0
            self.buffer = []
            self.position = 0
        }
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        if initialPadFrames > 0, channelCount > 0 {
            buffer.append(contentsOf: repeatElement(0, count: initialPadFrames * channelCount))
        }
        initialPadRemaining = initialPadFrames
        position = Double(initialPadFrames)
    }

    mutating func process(_ pcm: [Float], frameCount: Int) -> [Float] {
        guard frameCount > 0,
              channelCount > 0,
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              outputSampleRate.isFinite,
              outputSampleRate > 0
        else { return [] }

        let sampleCount = min(frameCount * channelCount, pcm.count)
        guard sampleCount >= channelCount else { return [] }

        if abs(inputSampleRate - outputSampleRate) <= 0.5 {
            return Array(pcm.prefix(sampleCount))
        }

        buffer.append(contentsOf: pcm.prefix(sampleCount))

        let step = inputSampleRate / outputSampleRate
        let availableFrames = buffer.count / channelCount
        let halfTaps = PolyphaseKernel.halfTaps
        let taps = PolyphaseKernel.taps
        guard step.isFinite, step > 0, let kernel, availableFrames >= taps else { return [] }

        let firstCenter = Int(position.rounded(.towardZero))
        guard firstCenter + halfTaps < availableFrames else { return [] }

        let estimatedFrames = Int(ceil((Double(availableFrames - halfTaps) - position) / step)) + 1
        var output: [Float] = []
        output.reserveCapacity(max(1, estimatedFrames) * channelCount)

        let phaseScale = Double(PolyphaseKernel.phaseCount)
        let channels = channelCount

        buffer.withUnsafeBufferPointer { srcBuf in
            kernel.weights.withUnsafeBufferPointer { tablePtr in
                guard let srcBase = srcBuf.baseAddress,
                      let weightsBase = tablePtr.baseAddress else { return }

                while true {
                    let center = Int(position.rounded(.towardZero))
                    let lastTapFrame = center + halfTaps
                    guard lastTapFrame < availableFrames else { break }

                    let frac = position - Double(center)
                    let scaledPhase = frac * phaseScale
                    let phaseIndex = min(PolyphaseKernel.phaseCount - 1, max(0, Int(scaledPhase)))
                    let alpha = Float(scaledPhase - Double(phaseIndex))

                    let w0Ptr = weightsBase.advanced(by: phaseIndex * taps)
                    let w1Ptr = w0Ptr.advanced(by: taps)
                    let startInputFrame = center - (halfTaps - 1)
                    let srcFrameBase = srcBase.advanced(by: startInputFrame * channels)

                    if channels == 2 {
                        var acc0: Float = 0
                        var acc1: Float = 0
                        for tap in 0..<taps {
                            let w0 = w0Ptr[tap]
                            let w = w0 + (w1Ptr[tap] - w0) * alpha
                            let s = srcFrameBase.advanced(by: tap * 2)
                            acc0 += w * s[0]
                            acc1 += w * s[1]
                        }
                        output.append(acc0)
                        output.append(acc1)
                    } else if channels == 1 {
                        var acc: Float = 0
                        for tap in 0..<taps {
                            let w0 = w0Ptr[tap]
                            let w = w0 + (w1Ptr[tap] - w0) * alpha
                            acc += w * srcFrameBase[tap]
                        }
                        output.append(acc)
                    } else {
                        for channel in 0..<channels {
                            var acc: Float = 0
                            for tap in 0..<taps {
                                let w0 = w0Ptr[tap]
                                let w = w0 + (w1Ptr[tap] - w0) * alpha
                                acc += w * srcFrameBase[tap * channels + channel]
                            }
                            output.append(acc)
                        }
                    }

                    position += step
                }
            }
        }

        discardConsumedInput(availableFrames: availableFrames)
        return output
    }

    private mutating func discardConsumedInput(availableFrames: Int) {
        let halfTaps = PolyphaseKernel.halfTaps
        let taps = PolyphaseKernel.taps
        let minNeededStart = max(0, Int(position.rounded(.towardZero)) - (halfTaps - 1))
        let discardFrames = min(
            max(0, availableFrames - taps),
            minNeededStart
        )
        guard discardFrames > 0 else { return }
        buffer.removeFirst(discardFrames * channelCount)
        position -= Double(discardFrames)
        initialPadRemaining = max(0, initialPadRemaining - discardFrames)
    }
}
