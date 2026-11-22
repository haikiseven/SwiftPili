import Darwin
import Foundation
import Synchronization

// MARK: - Main-thread identity

/// The main thread's own identity, adopted ONCE from the main thread at launch.
///
/// Two values that cannot be obtained from anywhere else and are the difference
/// between a freeze report that names a culprit and one that shrugs:
///
///  - **A pthread handle**, so a watchdog on another thread can direct a signal
///    at the main thread specifically (`FreezeStackSampler`). There is no API
///    that turns "the main thread" into a `pthread_t` from a background thread —
///    `pthread_main_np()` answers only about the CALLER — so it has to be
///    captured while we are on it.
///  - **A Mach port name**, so the thread census can say which row of
///    `task_threads` IS main. Comparing names would not do: the census reads
///    `thread_extended_info.pth_name`, and nothing on Darwin names the main
///    thread. Every field freeze report in this project's archive says
///    `threads[unnamed:99%]`, and an unnamed thread at 99% is very likely main —
///    but "likely" is exactly the kind of inference a diagnostic should not be
///    forcing its reader to make.
///
/// It also NAMES the main thread, which is the cheapest permanent diagnostic win
/// available here: from now on `[Power]` and `[Freeze]` lines print `main:99%`
/// instead of `unnamed:99%`, in Release too. This is safe in a way that naming a
/// dispatch worker is NOT — libdispatch recycles worker threads across queues,
/// so a name stamped on one would persist onto unrelated work and make the next
/// report lie, whereas the main thread is ours for the whole process lifetime
/// and can never be re-used for anything else. That is why the only
/// `pthread_setname_np` in this app is here.
enum MainThreadIdentity {
    /// Non-Sendable pointer types cannot be plain statics under Swift 6 strict
    /// concurrency. `nonisolated(unsafe)` is honest about the contract: written
    /// exactly once from the main thread before any reader exists, read-only
    /// thereafter — the same contract as `PlayerLog.isEnabled`.
    private nonisolated(unsafe) static var handle: pthread_t?
    private nonisolated(unsafe) static var port: mach_port_t = 0

    /// Mach port name of the main thread, or 0 when it was never adopted.
    static var machPort: mach_port_t { port }

    /// pthread handle of the main thread, or nil when it was never adopted.
    static var pthreadHandle: pthread_t? { handle }

    /// Called from the app's launch task, which is `@MainActor` — the isolation
    /// IS the correctness argument, so it is stated in the signature rather than
    /// asserted in a comment. Idempotent.
    ///
    /// Deliberately NOT inside `FreezeWatchdog.start()`, which is `#if DEBUG`:
    /// the thread NAME is worth having in every configuration, because
    /// `PowerProfiler`'s `[Power]` lines run on Release builds whenever Debug
    /// Logging is on and they print the same thread table.
    @MainActor
    static func adopt() {
        guard port == 0 else { return }
        handle = pthread_self()
        // `mach_thread_self()` hands out a send right with one user reference.
        // It is deliberately NEVER deallocated: the port name has to stay valid
        // and stable for the life of the process, and within one task the kernel
        // hands `task_threads` the SAME name for the same thread, which is what
        // makes the census comparison work at all.
        port = mach_thread_self()
        pthread_setname_np("main")
        FreezeStackSampler.arm()
    }
}

// MARK: - Sampler

/// Captures the main thread's call stack WHILE the main thread is wedged.
///
/// `HangDiagnosticsReporter` states — correctly, for the mechanism it was
/// describing — that the blocked frames cannot be named from inside the process
/// because "the only thread that could walk the main thread's stack is the one
/// that is stuck". That is true of any approach that needs main to RUN. It is
/// not true of a signal: a thread-directed signal is delivered on the target
/// thread's own stack, and the kernel delivers it whether that thread is
/// spinning in a loop, blocked on a lock, or parked in a syscall. So the
/// handler runs where nothing else can — on the frozen thread — walks the
/// frame-pointer chain, and hands the addresses back.
///
/// **Why a signal and not `thread_suspend` + `thread_get_state`.** The
/// crash-reporter approach (suspend the target, read `arm_thread_state64_t`,
/// walk `fp` by hand) reaches the same place, and it is what this project would
/// have to write if the target were a thread we cannot signal. It was rejected
/// here for two reasons. It hard-codes an ABI: the register struct is spelled
/// differently under pointer authentication (`__opaque_fp` vs `__fp`) and a
/// frame walk written from memory against the wrong spelling is a compile error
/// at best and a wrong stack at worst — and this repo is worked on from a host
/// with no iOS SDK, so that code could not be typechecked before shipping. And
/// it deadlocks by construction: between suspend and resume the sampler may not
/// allocate, because the suspended thread may be holding the malloc lock, which
/// makes every mistake in that window a hang inside a hang diagnostic. The
/// signal path allocates nothing in the handler and suspends nothing.
///
/// **What the handler is allowed to do, and it is almost nothing.** Two
/// lock-free atomic accesses and `backtrace()`, which walks frame pointers into
/// a buffer the caller already owns and allocates nothing. No `malloc`, no
/// `String`, no `os_unfair_lock`, no `PlayerLog` — every one of those can be
/// held by the thread we interrupted, and a deadlock inside a freeze diagnostic
/// is the one failure this file must never cause. Symbolication and formatting
/// happen afterwards, on the sampler's own queue, from a plain array of
/// integers.
///
/// **Cost.** Zero until a freeze: the observer is `FreezeWatchdog`'s existing
/// 10Hz queue tick, which already computes the acknowledgement age, and nothing
/// here runs until that age crosses 500ms. During a freeze it is one signal,
/// one frame walk (tens of microseconds) and one bounded poll — on a thread
/// that is by definition not making progress anyway. Rate-limited to one sample
/// per 750ms and `maxSamplesPerEpisode` per freeze, so a long freeze produces a
/// readable handful of stacks rather than a firehose.
///
/// **Skipped under a debugger.** lldb intercepts signals, and a `SIGPROF` it
/// decides to stop on would turn a diagnostic into an interruption. Same
/// doctrine as the marker suppression in `FreezeWatchdog`: a reading taken with
/// a debugger attached is not trustworthy anyway.
enum FreezeStackSampler {
    // MARK: Handshake state

    /// Deep enough for a SwiftUI update storm (AttributeGraph recursion is the
    /// realistic worst case here) without making the handler's write large.
    private static let frameCapacity = 192
    /// How many frames a report prints. The leaf frames are the answer; a
    /// 190-frame dump is what makes a report unreadable.
    private static let printedFrameLimit = 40

    private static let idle: UInt32 = 0
    private static let requested: UInt32 = 1
    private static let captured: UInt32 = 2

    /// The whole cross-thread handshake. Release/acquire, not relaxed: the
    /// handler writes `frameCount` and the buffer BEFORE the releasing store,
    /// and the sampler reads them AFTER the acquiring load, so the pair is what
    /// publishes the frames. Getting this wrong reads a stale count.
    private static let state = Atomic<UInt32>(0)
    private nonisolated(unsafe) static var frameCount: Int32 = 0
    private nonisolated(unsafe) static let frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frameCapacity)
        buffer.initialize(repeating: nil, count: frameCapacity)
        return buffer
    }()

    /// SIGPROF, and the choice matters. It is the signal sampling profilers
    /// conventionally use, nothing in this app or in libVLC raises it, and
    /// Darwin's `signal()` installs a BSD-semantics handler — `SA_RESTART`, so a
    /// syscall the target was sitting in RESUMES instead of failing with EINTR.
    /// A sampler that made unrelated reads fail would be a worse bug than the
    /// freeze it is measuring.
    private static let samplingSignal = SIGPROF

    private static let handler: @convention(c) (Int32) -> Void = { _ in
        // Runs ON the frozen thread. See the type comment for what may and may
        // not appear here; the answer is "these three lines".
        guard FreezeStackSampler.state.load(ordering: .acquiring) == FreezeStackSampler.requested
        else { return }
        FreezeStackSampler.frameCount = backtrace(
            FreezeStackSampler.frameBuffer,
            Int32(FreezeStackSampler.frameCapacity)
        )
        FreezeStackSampler.state.store(FreezeStackSampler.captured, ordering: .releasing)
    }

    /// Installs the handler and forces every lazily-initialised static it
    /// touches. The forcing is load-bearing: a Swift `static let` runs its
    /// initialiser behind `swift_once`, which allocates and takes a lock — and
    /// the first thread to reach it would be the signal handler, on a thread
    /// that may be holding that very allocator. So they are all realised here,
    /// on the main thread, at launch, before any signal can be sent.
    ///
    /// `#if DEBUG`, matching `FreezeWatchdog.start()`, which is the only thing
    /// that ever requests a sample. Installing a handler in Release would change
    /// this process's SIGPROF disposition for a requester that cannot exist —
    /// a permanent, if tiny, change to shipping behaviour bought for nothing.
    /// `MainThreadIdentity.adopt()`'s other two jobs (the thread name and the
    /// census port) stay unconditional, because `[Power]` prints the thread
    /// table on Release builds too.
    static func arm() {
        #if DEBUG
        _ = frameBuffer
        _ = handler
        // Every static the HANDLER reads, realised here rather than there. In a
        // DEBUG build nothing is optimised, so each of these is a genuine
        // `swift_once`-guarded global accessor on first touch — and the one
        // thread that must never run a `swift_once` initialiser is the one
        // interrupted mid-allocation. `frameBuffer` and `handler` were already
        // forced; `frameCount`, `frameCapacity` and the three phase constants
        // were not, and the handler reads all five.
        frameCount = 0
        _ = (idle, requested, captured, frameCapacity)
        state.store(idle, ordering: .relaxed)
        _ = signal(samplingSignal, handler)
        // Set only where the handler was actually installed. `requestSample`
        // refuses without it, because the ONLY thing standing between a
        // `pthread_kill(main, SIGPROF)` and SIGPROF's default disposition —
        // which terminates the process — is that a handler exists. Gating the
        // send on `MainThreadIdentity.pthreadHandle` did not express that:
        // `adopt()` runs in Release too, so the handle is non-nil in exactly
        // the configuration where the handler is absent, and the invariant was
        // held only by the `#if DEBUG` on a caller two files away.
        handlerInstalled = true
        #endif
    }

    /// Whether `arm()` installed the SIGPROF handler. Written once from the main
    /// thread at launch before any reader exists — same contract as
    /// `MainThreadIdentity`'s statics and `PlayerLog.isEnabled`.
    private nonisolated(unsafe) static var handlerInstalled = false

    // MARK: Queue

    /// Its own queue, NOT the watchdog's. `capture` blocks for up to
    /// `waitBudget` waiting for the frozen thread to answer, and the watchdog's
    /// tick chain is the clock the whole `ackAge` measurement rests on —
    /// blocking it would make the sampler inflate the number it exists to
    /// explain. `.utility`, because this is post-hoc forensics and the freeze is
    /// already happening.
    private static let queue = DispatchQueue(
        label: "com.swiftpili.freeze-stack-sampler",
        qos: .utility
    )

    /// Queue-only state; no lock needed, `queue` is serial.
    private nonisolated(unsafe) static var lastSampleAt: TimeInterval = 0
    private nonisolated(unsafe) static var samplesThisEpisode = 0
    private nonisolated(unsafe) static var escalatedThisEpisode = false

    private static let minimumInterval: TimeInterval = 0.75
    private static let maxSamplesPerEpisode = 6
    /// How long to wait for the frozen thread to answer. A target that has
    /// SIGPROF blocked (some vendor worker threads do) or that is
    /// uninterruptibly in the kernel never answers at all — that is a real
    /// outcome and is reported as one rather than waited out.
    private static let waitBudgetMicroseconds: UInt32 = 150_000
    private static let pollIntervalMicroseconds: UInt32 = 2000

    /// A fresh freeze gets a fresh budget. Called when `FreezeWatchdog` opens an
    /// episode, so a run of short stalls cannot exhaust the allowance that the
    /// next multi-second freeze needs.
    static func beginEpisode(access: ExperimentalAccessReceipt?) {
        guard let access, access.isValid else { return }
        queue.async {
            guard access.isValid else { return }
            samplesThisEpisode = 0
            escalatedThisEpisode = false
            lastSampleAt = 0
        }
    }

    /// Ask for a stack. Returns immediately; the sample and its report happen on
    /// `queue`.
    ///
    /// - Parameter escalated: the freeze crossed `FreezeClassifier.freezeSeconds`.
    ///   The first escalated request bypasses the interval limiter, so the tier
    ///   the user actually notices always has a stack even when the 500ms
    ///   request was rate-limited away.
    static func requestSample(
        reason: String,
        verdict: String,
        ackAge: TimeInterval,
        escalated: Bool,
        access: ExperimentalAccessReceipt?
    ) {
        // The single admission point for the signal: no handler, no send.
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
        // A breakpoint pause is indistinguishable from a hang by duration, and
        // lldb may stop the process on the signal. Same rule the durable marker
        // already applies.
        guard !FreezeWatchdog.isDebuggerAttached() else { return }
        guard samplesThisEpisode < maxSamplesPerEpisode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let bypass = escalated && !escalatedThisEpisode
        guard bypass || now - lastSampleAt >= minimumInterval else { return }
        if bypass { escalatedThisEpisode = true }
        lastSampleAt = now
        samplesThisEpisode += 1

        // Census FIRST, so the CPU/run-state numbers describe the same instant
        // as the stack rather than the instant after it. They are still not the
        // SAME instant — the Mach walk takes about a millisecond and the signal
        // round-trip below is bounded only by `waitBudget` — so the gap is
        // measured and printed. `state=running` next to a CPU-bound verdict is
        // the discriminator this whole instrument exists to produce, and a
        // reader has to be able to see how far apart its two halves were taken.
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

        // The reported symptom is "one unnamed thread at 98–99%", and if that
        // thread is not main the census line above is where it is named — by
        // run state and CPU, which is as far as this can honestly go.
        //
        // **Why there is no stack for it.** Signalling an arbitrary thread needs
        // `pthread_from_mach_thread_np(port)`, and the port name in a
        // `ThreadSample` is already dead by the time it is read: the Mach walk
        // deallocates every name it was handed before it returns (it must, or
        // each census would leak one send right per thread), and a freed name is
        // free to be reused by the next port insertion. Sending a sampling
        // signal down a recycled name means sampling a DIFFERENT thread and
        // labelling the result with this one's identity — a wrong answer, which
        // is worse than no answer. Resolving the pthread inside the walk while
        // the reference is still held would fix the recycling, and then leave a
        // second hazard: a `pthread_t` for a thread that exited in between is
        // freed memory, and `pthread_kill` on it is a use-after-free in the one
        // piece of code that must never be the thing that kills the process.
        //
        // So: main only. Naming the main thread (`MainThreadIdentity.adopt()`)
        // is what makes that sufficient for the reported case — an `unnamed:99%`
        // that is really main now says `main:99%/running`, and its stack is
        // right here. If a future report shows a genuinely non-main thread
        // burning a core, the safe way to get its stack is to resolve and RETAIN
        // its port inside the walk, not to reuse a name the walk released.
        if let hottest = system.hottestThread, !hottest.isMain {
            out += "\n  hottest is not main: \(hottest.label)"
            out += " — identity only; see the note in FreezeStackSampler for why"
            out += " a non-main stack is not taken"
        }

        guard access.isValid else { return }
        PlayerLog.diagnostic(out)
    }

    // MARK: Capture

    /// The main thread's census row and its stack. `census` may be nil only if
    /// the Mach walk failed outright — the walk keeps main even at 0% CPU
    /// precisely so "main is idle" and "main is missing" stay distinguishable.
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
        // Where the interrupted stack starts. Everything above it is this
        // sampler's own signal-delivery path, and it is printed rather than
        // dropped — but it must not be read as the frozen thread's leaf.
        let boundary = interruptedFrameIndex(symbolicated)
        let interrupted = Array(symbolicated[(boundary ?? 0)...])
        out += "\n    frames=\(frames.count)"
        out += " delivery=\(boundary.map(String.init) ?? "boundary-not-found")"
        // The two halves of the discriminator, and how far apart they were read.
        out += " censusToStack=\(milliseconds(censusToStack))"
        out += "\n    where=\(hypothesis(interrupted, thread: thread))"
        // Stated on every sample, not once in a doc: the addresses below are
        // exact and the symbol names are a best effort (see `describe`), and a
        // reader who assumes otherwise draws the wrong conclusion.
        out += "\n    ⚠️ image+offset is authoritative; symbolicate offline with"
        out += " `atos -o <binary> -arch arm64 -l <image load address>`"
        // The limit applies to the INTERRUPTED frames, so the sampler's own
        // delivery frames can never crowd out the answer.
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
        // Load addresses, once per image, so every offset above is usable.
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

    /// Sends the signal and waits, bounded, for the handler to publish.
    /// Serialised by `queue`, so there is never more than one outstanding
    /// request and the single shared buffer needs no ownership protocol.
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
            // Leave the slot idle so a blocked target cannot poison the next
            // sample by having its handler fire late into a live request.
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
        /// The nearest preceding exported symbol, whether or not it was close
        /// enough to print (see `describe`). Kept separately because the signal
        /// trampoline has to be findable by name, and matching on `text` would
        /// be matching on a formatted string.
        let symbol: String?
    }

    /// Index of the first frame that belongs to the INTERRUPTED stack, or nil
    /// when the boundary could not be located.
    ///
    /// `backtrace()` cannot know it was called from a signal handler: it walks
    /// from its own caller. So frame 0 is the handler in THIS file, under it is
    /// the trampoline the kernel delivered the signal through (`_sigtramp`, in
    /// `libsystem_platform.dylib`), and only then the frames that were actually
    /// executing. Verified off-device on the same mechanism — a thread blocked
    /// in `read(2)`, signalled with `pthread_kill` — which produced
    /// `#00 handler / #01 trampoline / #02 read / #03… the blocked call chain`.
    ///
    /// It mattered twice. `#00` as printed named the sampler's own handler,
    /// which reads as "the main thread was executing FreezeStackSampler" — the
    /// diagnostic accusing itself of the freeze. And `hypothesis` tests whether
    /// the LEAF frame sits in `libsystem_kernel`, which a handler frame in the
    /// app's own image can never be, so `BLOCKED in a syscall` — the verdict
    /// that names a lock or a wait exactly — was unreachable, and every blocked
    /// freeze fell through to the weaker run-state branch.
    ///
    /// Fails OPEN: with no trampoline frame found, the frames are used exactly
    /// as captured and the sample says `delivery=boundary-not-found`, because
    /// silently slicing at a guessed depth would move the leaf into somebody
    /// else's frame. Only the first few frames are searched — the trampoline is
    /// directly beneath the handler, and `os_unfair_lock_lock` also lives in
    /// `libsystem_platform.dylib`, so an unbounded search could match a genuine
    /// interrupted frame instead.
    private static func interruptedFrameIndex(_ frames: [Frame]) -> Int? {
        for (index, frame) in frames.prefix(deliveryFrameSearchDepth).enumerated() {
            let isTrampoline = frame.symbol?.contains("sigtramp") == true
                || frame.image == "libsystem_platform.dylib"
            guard isTrampoline, index + 1 < frames.count else { continue }
            return index + 1
        }
        return nil
    }

    /// How deep to look for the trampoline. The handler is one Swift closure, so
    /// two or three frames of delivery path is the realistic worst case; eight
    /// is slack for a thunk without reaching into the interrupted stack.
    private static let deliveryFrameSearchDepth = 8

    /// One frame, rendered honestly.
    ///
    /// `image + 0x<offset>` is always printed and is always exact: `dladdr`'s
    /// `dli_fbase` is the image's load address, and `atos -l` takes exactly
    /// that. The SYMBOL is a different matter — `dladdr` can only answer from
    /// the dynamic symbol table, so for a function that is not exported it
    /// returns the nearest PRECEDING exported symbol, which for the app's own
    /// binary is routinely a different function entirely. A wrong symbol is
    /// worse than an address, so the name is printed ONLY when the offset from
    /// it is small enough that it is very likely the real containing function,
    /// and the offset is always printed beside it so the reader can discount it.
    ///
    /// Kingfisher, SwiftVLC and every SPM dependency are statically linked into
    /// the app binary, so they appear under the app's image name and can only be
    /// resolved offline — one more reason the offsets, not the names, are the
    /// artifact worth pasting into a bug.
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

    /// How far past an exported symbol a pc may sit before the name stops being
    /// evidence. 4KB is generous for one function and tight enough that a name
    /// picked up from three functions earlier is dropped rather than printed.
    private static let nearSymbolWindow: UInt = 0x1000

    /// A named hypothesis with the evidence it rests on — never a bare verdict,
    /// because the two inputs it can trust absolutely (the kernel run state and
    /// the IMAGE names, which `dladdr` always gets right) do not by themselves
    /// identify a function.
    ///
    /// The three cases it separates are the three that change what you do next:
    /// blocked in a syscall (the leaf is in `libsystem_kernel`, where the symbol
    /// IS exported and exact, so the wait is named exactly), burning CPU
    /// (runnable with no kernel leaf), and neither.
    ///
    /// `frames` must already start at the INTERRUPTED frame
    /// (`interruptedFrameIndex`) — the leaf test is the whole verdict, and the
    /// raw capture's leaf is this sampler's own signal handler. When the
    /// boundary could not be located the caller says so on the same line, so a
    /// verdict computed from an unsliced capture is not read as a clean one.
    /// The image histogram then
    /// says WHOSE code: `SwiftUI`/`AttributeGraph` is body/layout/invalidation,
    /// `ImageIO`/`CoreGraphics` is decode, `UIKitCore` is layout or navigation,
    /// `libswiftCore`/`libobjc` is runtime overhead, and the app's own image is
    /// everything statically linked into it.
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
