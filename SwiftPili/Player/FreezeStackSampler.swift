import Darwin
import Foundation
import Synchronization

// MARK: - Main-thread identity

enum MainThreadIdentity {
    private nonisolated(unsafe) static var handle: pthread_t?
    private nonisolated(unsafe) static var port: mach_port_t = 0

    static var machPort: mach_port_t { port }

    static var pthreadHandle: pthread_t? { handle }

    @MainActor
    static func adopt() {
        guard port == 0 else { return }
        handle = pthread_self()
        port = mach_thread_self()
        pthread_setname_np("main")
        FreezeStackSampler.arm()
    }
}

// MARK: - Sampler

enum FreezeStackSampler {
    // MARK: Handshake state

    private static let frameCapacity = 192
    private static let printedFrameLimit = 40

    private static let idle: UInt32 = 0
    private static let requested: UInt32 = 1
    private static let captured: UInt32 = 2

    private static let state = Atomic<UInt32>(0)
    private nonisolated(unsafe) static var frameCount: Int32 = 0
    private nonisolated(unsafe) static let frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frameCapacity)
        buffer.initialize(repeating: nil, count: frameCapacity)
        return buffer
    }()

    private static let samplingSignal = SIGPROF

    private static let handler: @convention(c) (Int32) -> Void = { _ in
        guard FreezeStackSampler.state.load(ordering: .acquiring) == FreezeStackSampler.requested
        else { return }
        FreezeStackSampler.frameCount = backtrace(
            FreezeStackSampler.frameBuffer,
            Int32(FreezeStackSampler.frameCapacity)
        )
        FreezeStackSampler.state.store(FreezeStackSampler.captured, ordering: .releasing)
    }

    static func arm() {
        #if DEBUG
        _ = frameBuffer
        _ = handler
        frameCount = 0
        _ = (idle, requested, captured, frameCapacity)
        state.store(idle, ordering: .relaxed)
        _ = signal(samplingSignal, handler)
        handlerInstalled = true
        #endif
    }

    private nonisolated(unsafe) static var handlerInstalled = false

    // MARK: Queue

    private static let queue = DispatchQueue(
        label: "com.swiftpili.freeze-stack-sampler",
        qos: .utility
    )

    private nonisolated(unsafe) static var lastSampleAt: TimeInterval = 0
    private nonisolated(unsafe) static var samplesThisEpisode = 0
    private nonisolated(unsafe) static var escalatedThisEpisode = false

    private static let minimumInterval: TimeInterval = 0.75
    private static let maxSamplesPerEpisode = 6
    private static let waitBudgetMicroseconds: UInt32 = 150_000
    private static let pollIntervalMicroseconds: UInt32 = 2000

    static func beginEpisode(access: ExperimentalAccessReceipt?) {
        guard let access, access.isValid else { return }
        queue.async {
            guard access.isValid else { return }
            samplesThisEpisode = 0
            escalatedThisEpisode = false
            lastSampleAt = 0
        }
    }

    static func requestSample(
        reason: String,
        verdict: String,
        ackAge: TimeInterval,
        escalated: Bool,
        access: ExperimentalAccessReceipt?
    ) {
        guard handlerInstalled, MainThreadIdentity.pthreadHandle != nil,
              let access, access.isValid else { return }
        queue.async {
            guard access.isValid else { return }
            perform(reason: reason, verdict: verdict, ackAge: ackAge, escalated: escalated, access: access)
        }
    }

    private static func perform(
        reason: String,
        verdict: String,
        ackAge: TimeInterval,
        escalated: Bool,
        access: ExperimentalAccessReceipt
    ) {
        guard access.isValid else { return }
        guard !FreezeWatchdog.isDebuggerAttached() else { return }
        guard samplesThisEpisode < maxSamplesPerEpisode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let bypass = escalated && !escalatedThisEpisode
        guard bypass || now - lastSampleAt >= minimumInterval else { return }
        if bypass { escalatedThisEpisode = true }
        lastSampleAt = now
        samplesThisEpisode += 1

        let censusAt = ProcessInfo.processInfo.systemUptime
        let system = PowerProfiler.sampleSystem()
        let main = system.threads.first { $0.isMain }

        var out = "[Freeze] stack sample #\(samplesThisEpisode) reason=\(reason) "
        out += "verdict=\(verdict) age=\(milliseconds(ackAge))"
        out += "\n  cpu=\(String(format: "%.0f", system.cpuPercent))% "
        out += "mem=\(system.footprintMB)MB threads=\(system.threadCount)"
        if let hottest = system.hottestThread {
            out += " hottest=\(hottest.label)"
        }

        guard access.isValid else { return }
        out += "\n" + renderMainStack(census: main, censusAt: censusAt)

        if let hottest = system.hottestThread, !hottest.isMain {
            out += "\n  hottest is not main: \(hottest.label)"
            out += " — identity only; see the note in FreezeStackSampler for why"
            out += " a non-main stack is not taken"
        }

        guard access.isValid else { return }
        PlayerLog.diagnostic(out)
    }

    // MARK: Capture

    private static func renderMainStack(
        census thread: PowerProfiler.ThreadSample?,
        censusAt: TimeInterval
    ) -> String {
        var out = "  main: "
        if let thread {
            out += "\(thread.displayName) state=\(thread.runStateLabel) "
            out += "cpu=\(String(format: "%.0f", thread.usage))%"
        } else {
            out += "not found in the thread census"
        }
        guard let handle = MainThreadIdentity.pthreadHandle else {
            out += "\n    stack: unavailable (main-thread identity was never adopted)"
            return out
        }
        let frames = capture(handle)
        let censusToStack = ProcessInfo.processInfo.systemUptime - censusAt
        guard !frames.isEmpty else {
            out += "\n    stack: NOT ANSWERED within "
            out += "\(Int(waitBudgetMicroseconds / 1000))ms — the thread has SIGPROF "
            out += "blocked, or is uninterruptibly in the kernel"
            return out
        }
        let symbolicated = frames.map(describe)
        let boundary = interruptedFrameIndex(symbolicated)
        let interrupted = Array(symbolicated[(boundary ?? 0)...])
        out += "\n    frames=\(frames.count)"
        out += " delivery=\(boundary.map(String.init) ?? "boundary-not-found")"
        out += " censusToStack=\(milliseconds(censusToStack))"
        out += "\n    where=\(hypothesis(interrupted, thread: thread))"
        out += "\n    ⚠️ image+offset is authoritative; symbolicate offline with"
        out += " `atos -o <binary> -arch arm64 -l <image load address>`"
        let printedLimit = (boundary ?? 0) + printedFrameLimit
        for (index, frame) in symbolicated.prefix(printedLimit).enumerated() {
            if let boundary, index == boundary {
                out += "\n    ── below: what the thread was executing when the"
                out += " signal arrived ──"
            }
            out += "\n    #\(String(format: "%02d", index)) \(frame.text)"
        }
        if symbolicated.count > printedLimit {
            out += "\n    … \(symbolicated.count - printedLimit) deeper frames omitted"
        }
        var listed: [String: UInt] = [:]
        for frame in symbolicated where frame.image != nil {
            listed[frame.image!] = frame.imageBase
        }
        if !listed.isEmpty {
            out += "\n    images: " + listed.sorted { $0.key < $1.key }
                .map { "\($0.key)@0x\(String($0.value, radix: 16))" }
                .joined(separator: "  ")
        }
        return out
    }

    private static func capture(_ thread: pthread_t) -> [UInt] {
        state.store(requested, ordering: .releasing)
        guard pthread_kill(thread, samplingSignal) == 0 else {
            state.store(idle, ordering: .relaxed)
            return []
        }
        var waited: UInt32 = 0
        while state.load(ordering: .acquiring) != captured, waited < waitBudgetMicroseconds {
            usleep(pollIntervalMicroseconds)
            waited += pollIntervalMicroseconds
        }
        guard state.load(ordering: .acquiring) == captured else {
            state.store(idle, ordering: .relaxed)
            return []
        }
        let count = min(Int(frameCount), frameCapacity)
        var frames: [UInt] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            frames.append(UInt(bitPattern: frameBuffer[index]))
        }
        state.store(idle, ordering: .relaxed)
        return frames
    }

    // MARK: Symbolication

    private struct Frame {
        let text: String
        let image: String?
        let imageBase: UInt
        let symbol: String?
    }

    private static func interruptedFrameIndex(_ frames: [Frame]) -> Int? {
        for (index, frame) in frames.prefix(deliveryFrameSearchDepth).enumerated() {
            let isTrampoline = frame.symbol?.contains("sigtramp") == true
                || frame.image == "libsystem_platform.dylib"
            guard isTrampoline, index + 1 < frames.count else { continue }
            return index + 1
        }
        return nil
    }

    private static let deliveryFrameSearchDepth = 8

    private static func describe(_ address: UInt) -> Frame {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0,
              let pathPointer = info.dli_fname
        else {
            return Frame(
                text: String(format: "0x%016lx  <unmapped>", address),
                image: nil,
                imageBase: 0,
                symbol: nil
            )
        }
        let image = (String(cString: pathPointer) as NSString).lastPathComponent
        let base = UInt(bitPattern: info.dli_fbase)
        var text = image + " + 0x" + String(address >= base ? address - base : 0, radix: 16)
        var symbol: String?
        if let symbolPointer = info.dli_sname {
            symbol = String(cString: symbolPointer)
            let symbolAddress = UInt(bitPattern: info.dli_saddr)
            let delta = address >= symbolAddress ? address - symbolAddress : UInt.max
            if delta < nearSymbolWindow, let symbol {
                text += "  (" + symbol + "+0x" + String(delta, radix: 16) + ")"
            }
        }
        return Frame(text: text, image: image, imageBase: base, symbol: symbol)
    }

    private static let nearSymbolWindow: UInt = 0x1000

    private static func hypothesis(
        _ frames: [Frame],
        thread: PowerProfiler.ThreadSample?
    ) -> String {
        var histogram: [String: Int] = [:]
        for frame in frames {
            histogram[frame.image ?? "<unmapped>", default: 0] += 1
        }
        let images = histogram.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")

        let leaf = frames.first
        let leafIsKernel = leaf?.image == "libsystem_kernel.dylib"
        let verdict: String
        if leafIsKernel {
            verdict = "BLOCKED in a syscall — the #00 symbol names the wait"
        } else if thread?.runState == TH_STATE_RUNNING {
            verdict = "CPU-BOUND (runnable, no kernel leaf frame)"
        } else if let thread {
            verdict = "run state \(thread.runStateLabel) with no kernel leaf frame"
        } else {
            verdict = "unclassified (thread not found in the census)"
        }
        return verdict + " [images: " + images + "]"
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int(seconds * 1000))ms"
    }
}
