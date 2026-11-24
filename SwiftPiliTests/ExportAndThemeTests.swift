import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation
import Synchronization
import Testing
import UIKit
@testable import SwiftPili

// MARK: - Test Doubles & Helpers

private actor ExportTestGate {
    private var entered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let waiters = enterWaiters
        enterWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class MockExportNativeBackend: DownloadExportNativeBackend {
    static let defaultInventory = ExportMediaInventory(
        width: 1920,
        height: 1080,
        duration: 30.0,
        videoCodec: "hevc",
        audioCodec: "aac",
        hdr: false,
        dolbyVisionProfile: nil,
        recipes: [
            ExportRecipe(codec: .h264, resolution: .hd1080, color: .sdr),
            ExportRecipe(codec: .hevc, resolution: .source, color: .sdr),
        ],
        canRemuxOriginal: true,
        estimatedOutputBytes: 4096
    )

    private let probeHandler: @Sendable (DownloadExportSource, ExportCancellation) async throws -> ExportMediaInventory
    private let executeHandler: @Sendable (
        ExportNativeRequest, ExportCancellation, @escaping @Sendable (Double) -> Void
    ) async throws -> ExportNativeResult

    init(
        probe: @escaping @Sendable (DownloadExportSource, ExportCancellation) async throws -> ExportMediaInventory = { _, _ in
            MockExportNativeBackend.defaultInventory
        },
        execute: @escaping @Sendable (
            ExportNativeRequest, ExportCancellation, @escaping @Sendable (Double) -> Void
        ) async throws -> ExportNativeResult
    ) {
        self.probeHandler = probe
        self.executeHandler = execute
    }

    func probe(
        source: DownloadExportSource,
        cancellation: ExportCancellation
    ) async throws -> ExportMediaInventory {
        try await probeHandler(source, cancellation)
    }

    func execute(
        request: ExportNativeRequest,
        cancellation: ExportCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportNativeResult {
        try await executeHandler(request, cancellation, progress)
    }
}

private struct TempExportWorkspace {
    let baseDirectory: URL
    let sourceDirectory: URL
    let exportRootDirectory: URL

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "SwiftPiliExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sources = base.appendingPathComponent("sources", isDirectory: true)
        let exports = base.appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        self.baseDirectory = base
        self.sourceDirectory = sources
        self.exportRootDirectory = exports
    }

    func makeSource(
        downloadID: String = "dl-export-1",
        title: String = "Sample Export Video",
        includeAudio: Bool = true
    ) throws -> DownloadExportSource {
        let videoURL = sourceDirectory.appendingPathComponent("\(downloadID)-video.m4s")
        try Data(repeating: 0x11, count: 512).write(to: videoURL)
        let audioURL: URL?
        if includeAudio {
            let url = sourceDirectory.appendingPathComponent("\(downloadID)-audio.m4s")
            try Data(repeating: 0x22, count: 256).write(to: url)
            audioURL = url
        } else {
            audioURL = nil
        }
        return DownloadExportSource(
            downloadID: downloadID,
            title: title,
            videoURL: videoURL,
            audioURL: audioURL
        )
    }

    func remainingExportEntries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: exportRootDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@MainActor
private func makeSyntheticFrameImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
}

private func makeOptions(
    filename: String = "Exported Clip",
    mode: ExportMode = .original
) -> ExportOptions {
    ExportOptions(
        filename: filename,
        mode: mode,
        codec: .hevc,
        resolution: .source,
        color: .sdr,
        includeAudio: true
    )
}

// MARK: - ExportOptions & ExportCancellation Tests

@Suite("ExportOptions & ExportCancellation")
struct ExportOptionsTests {
    @Test("ExportOptions sanitizes forbidden characters, extensions, whitespace, and length")
    func filenameSanitization() throws {
        let basic = makeOptions(filename: "My Video")
        #expect(basic.sanitizedFilename == "My Video.mp4")
        try basic.validate()

        let existingMP4 = makeOptions(filename: "Clip.mp4")
        #expect(existingMP4.sanitizedFilename == "Clip.mp4")
        try existingMP4.validate()

        let existingMOV = makeOptions(filename: "  Demo Clip.mov  ")
        #expect(existingMOV.sanitizedFilename == "Demo Clip.mp4")
        try existingMOV.validate()

        let forbiddenChars = makeOptions(filename: "Season 1/Ep\\02:Cut\nFinal")
        #expect(forbiddenChars.sanitizedFilename == "Season 1_Ep_02_Cut_Final.mp4")
        try forbiddenChars.validate()

        let overlyLong = makeOptions(filename: String(repeating: "a", count: 220))
        #expect(overlyLong.sanitizedFilename == String(repeating: "a", count: 180) + ".mp4")
        #expect(overlyLong.sanitizedFilename.count == 184)
        try overlyLong.validate()
    }

    @Test("ExportOptions.validate rejects empty and whitespace-only filenames")
    func filenameValidationRejectsInvalidNames() {
        for invalid in ["", "   ", "\t\n  "] {
            let options = makeOptions(filename: invalid)
            #expect(throws: ExportFailure.invalidFilename) {
                try options.validate()
            }
        }
    }

    @Test("ExportCancellation invokes handler exactly once and fires immediately if installed after cancel")
    func cancellationHandlerSemantics() {
        let token = ExportCancellation()
        let count = Mutex(0)
        token.install { count.withLock { $0 += 1 } }

        #expect(!token.isCancelled)
        token.cancel()
        token.cancel()
        #expect(token.isCancelled)
        #expect(count.withLock { $0 } == 1)

        let lateCount = Mutex(0)
        token.install { lateCount.withLock { $0 += 1 } }
        #expect(lateCount.withLock { $0 } == 1)
    }
}

// MARK: - DownloadExportCoordinator Tests

@Suite("DownloadExportCoordinator")
@MainActor
struct DownloadExportCoordinatorTests {
    @Test("Successful export produces artifact with accurate fileSizeBytes, clears activeJob, and releases source lock")
    func successfulExportLifecycle() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source = try workspace.makeSource(downloadID: "dl-success", title: "BV1ExportSuccess")
        let gate = ExportTestGate()
        let payloadSize = 2048

        let backend = MockExportNativeBackend { request, _, progress in
            await gate.markEntered()
            progress(0.5)
            await gate.waitUntilReleased()
            try Data(repeating: 0xAB, count: payloadSize).write(to: request.output)
            progress(1.0)
            return ExportNativeResult(validated: true)
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { _ in }
        )
        coordinator.configure(native: backend)

        let options = makeOptions(filename: "Holiday/Cut:01.mov")
        try await coordinator.start(source: source, options: options)

        await gate.waitUntilEntered()
        #expect(coordinator.hasActiveOperation)
        #expect(coordinator.sourceIsLocked(downloadID: source.downloadID))
        #expect(coordinator.activeJob?.state == .exporting)
        #expect(coordinator.activeJob?.title == source.title)

        // Starting another export while one is active must fail with .busy.
        await #expect(throws: ExportFailure.busy) {
            try await coordinator.start(source: source, options: options)
        }
        // dismissInactiveJob must be a no-op while active.
        coordinator.dismissInactiveJob()
        #expect(coordinator.activeJob != nil)

        await gate.release()
        let finished = await waitUntil { !coordinator.hasActiveOperation }
        #expect(finished)

        #expect(coordinator.activeJob == nil)
        #expect(!coordinator.sourceIsLocked(downloadID: source.downloadID))
        #expect(coordinator.artifacts.count == 1)

        let artifact = try #require(coordinator.artifacts.first)
        #expect(artifact.title == source.title)
        #expect(artifact.filename == "Holiday_Cut_01.mp4")
        #expect(artifact.fileSizeBytes == Int64(payloadSize))
        #expect(FileManager.default.fileExists(atPath: artifact.fileURL.path))
    }

    @Test("saveToPhotoLibrary invokes photoSaver, guards concurrent saves, removes artifact, and deletes temp job directory")
    func saveToPhotoLibraryCleansUpArtifactAndTempDirectory() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source = try workspace.makeSource(downloadID: "dl-photos", title: "Photo Library Export")
        let savedURLs = Mutex<[URL]>([])
        let saverGate = ExportTestGate()

        let backend = MockExportNativeBackend { request, _, _ in
            try Data(repeating: 0xCD, count: 1024).write(to: request.output)
            return ExportNativeResult(validated: true)
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { url in
                await saverGate.markEntered()
                await saverGate.waitUntilReleased()
                savedURLs.withLock { $0.append(url) }
            }
        )
        coordinator.configure(native: backend)

        try await coordinator.start(source: source, options: makeOptions(filename: "PhotosClip"))
        #expect(await waitUntil { !coordinator.hasActiveOperation })

        let artifact = try #require(coordinator.artifacts.first)
        let jobDirectory = artifact.fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: jobDirectory.path))

        let saveTask = Task { @MainActor in
            try await coordinator.saveToPhotoLibrary(id: artifact.id)
        }
        await saverGate.waitUntilEntered()
        #expect(coordinator.savingArtifactID == artifact.id)

        // Concurrent save requests are rejected with .busy; external save/discard are ignored while saving.
        await #expect(throws: ExportFailure.busy) {
            try await coordinator.saveToPhotoLibrary(id: artifact.id)
        }
        coordinator.completeExternalSave(id: artifact.id)
        coordinator.discard(id: artifact.id)
        #expect(coordinator.artifacts.count == 1)

        await saverGate.release()
        try await saveTask.value

        #expect(savedURLs.withLock { $0 } == [artifact.fileURL])
        #expect(coordinator.savingArtifactID == nil)
        #expect(coordinator.artifacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))

        // Unknown artifact ID reports .invalidOutput.
        await #expect(throws: ExportFailure.invalidOutput) {
            try await coordinator.saveToPhotoLibrary(id: UUID())
        }
    }

    @Test("saveToPhotoLibrary failure preserves artifact and temp file for retry or alternate destination")
    func saveToPhotoLibraryFailureKeepsArtifact() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source = try workspace.makeSource(downloadID: "dl-photo-denied")
        let backend = MockExportNativeBackend { request, _, _ in
            try Data(repeating: 0xEF, count: 512).write(to: request.output)
            return ExportNativeResult(validated: true)
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { _ in throw ExportFailure.photoLibraryDenied }
        )
        coordinator.configure(native: backend)

        try await coordinator.start(source: source, options: makeOptions(filename: "DeniedClip"))
        #expect(await waitUntil { !coordinator.hasActiveOperation })

        let artifact = try #require(coordinator.artifacts.first)
        await #expect(throws: ExportFailure.photoLibraryDenied) {
            try await coordinator.saveToPhotoLibrary(id: artifact.id)
        }

        #expect(coordinator.savingArtifactID == nil)
        #expect(coordinator.artifacts == [artifact])
        #expect(FileManager.default.fileExists(atPath: artifact.fileURL.path))
    }

    @Test("completeExternalSave and discard both remove artifact and delete temp job directory")
    func completeExternalSaveAndDiscardCleanup() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source1 = try workspace.makeSource(downloadID: "dl-files", title: "Files Export")
        let source2 = try workspace.makeSource(downloadID: "dl-discard", title: "Discarded Export")

        let backend = MockExportNativeBackend { request, _, _ in
            try Data(repeating: 0x77, count: 768).write(to: request.output)
            return ExportNativeResult(validated: true)
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { _ in }
        )
        coordinator.configure(native: backend)

        // First artifact: completeExternalSave (Files / Share)
        try await coordinator.start(source: source1, options: makeOptions(filename: "SavedToFiles"))
        #expect(await waitUntil { !coordinator.hasActiveOperation })
        let filesArtifact = try #require(coordinator.artifacts.first)
        let filesJobDir = filesArtifact.fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: filesJobDir.path))

        coordinator.completeExternalSave(id: filesArtifact.id)
        #expect(coordinator.artifacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: filesJobDir.path))

        // Second artifact: discard
        try await coordinator.start(source: source2, options: makeOptions(filename: "DiscardedClip"))
        #expect(await waitUntil { !coordinator.hasActiveOperation })
        let discardedArtifact = try #require(coordinator.artifacts.first)
        let discardedJobDir = discardedArtifact.fileURL.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: discardedJobDir.path))

        coordinator.discard(id: discardedArtifact.id)
        #expect(coordinator.artifacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: discardedJobDir.path))
    }

    @Test("Cancellation cleans temp directory, clears activeJob, and releases source waiters")
    func cancellationCleansUpAndReleasesSource() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source = try workspace.makeSource(downloadID: "dl-cancel", title: "Cancellable Export")
        let gate = ExportTestGate()

        let backend = MockExportNativeBackend { request, cancellation, _ in
            try Data(repeating: 0x33, count: 256).write(to: request.output)
            cancellation.install {
                Task { await gate.release() }
            }
            await gate.markEntered()
            await gate.waitUntilReleased()
            if cancellation.isCancelled {
                throw ExportFailure.cancelled
            }
            return ExportNativeResult(validated: true)
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { _ in }
        )
        coordinator.configure(native: backend)

        try await coordinator.start(source: source, options: makeOptions(filename: "CancelMe"))
        await gate.waitUntilEntered()
        #expect(coordinator.hasActiveOperation)
        #expect(coordinator.sourceIsLocked(downloadID: source.downloadID))
        #expect(coordinator.activeJob?.state == .exporting)

        await coordinator.cancelAndWaitForSource(downloadID: source.downloadID)

        #expect(!coordinator.hasActiveOperation)
        #expect(!coordinator.sourceIsLocked(downloadID: source.downloadID))
        #expect(coordinator.activeJob == nil)
        #expect(coordinator.artifacts.isEmpty)
        #expect(workspace.remainingExportEntries().isEmpty)
    }

    @Test("Native failure cleans temp directory, records .failed state, and dismissInactiveJob clears it")
    func nativeFailureAndDismissal() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let source = try workspace.makeSource(downloadID: "dl-fail", title: "Failing Export")
        let backend = MockExportNativeBackend { request, _, _ in
            try Data(repeating: 0x44, count: 128).write(to: request.output)
            throw ExportFailure.native("Muxer failed")
        }

        let coordinator = DownloadExportCoordinator(
            rootDirectory: workspace.exportRootDirectory,
            photoSaver: { _ in }
        )
        coordinator.configure(native: backend)

        try await coordinator.start(source: source, options: makeOptions(filename: "BrokenExport"))
        #expect(await waitUntil { !coordinator.hasActiveOperation })

        #expect(!coordinator.sourceIsLocked(downloadID: source.downloadID))
        #expect(coordinator.artifacts.isEmpty)
        #expect(coordinator.activeJob?.state == .failed)
        #expect(coordinator.activeJob?.error == "Muxer failed")
        #expect(workspace.remainingExportEntries().isEmpty)

        coordinator.dismissInactiveJob()
        #expect(coordinator.activeJob == nil)
    }
}

// MARK: - AccentTheme & AppIconSync Tests

@Suite("AccentTheme & AppIconSync", .serialized)
@MainActor
struct ThemeAndAppIconTests {
    @Test("AccentTheme.blue exposes System Blue identity and AppIconBlue alternate icon mapping")
    func systemBlueThemeAndAppIconSync() {
        #expect(AccentTheme.blue.rawValue == "System Blue")
        #expect(AccentTheme.blue.id == "System Blue")
        #expect(AccentTheme.blue.alternateIconName == "AppIconBlue")
        #expect(AccentTheme.bilibiliPink.alternateIconName == nil)
        #expect(AccentTheme.allCases.contains(.blue))

        #expect(AppIconSync.targetIconName(for: .blue) == "AppIconBlue")
        #expect(AppIconSync.targetIconName(for: .bilibiliPink) == nil)
        #expect(AppIconSync.targetIconName(for: nil) == nil)
    }

    @Test("AccentTheme.current defaults to .bilibiliPink and round-trips .blue cleanly")
    func accentThemePersistenceRoundTrip() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AccentTheme.storageKey)
        defer {
            if let original {
                defaults.set(original, forKey: AccentTheme.storageKey)
            } else {
                defaults.removeObject(forKey: AccentTheme.storageKey)
            }
        }

        defaults.removeObject(forKey: AccentTheme.storageKey)
        #expect(AccentTheme.current == .bilibiliPink)

        AccentTheme.current = .blue
        #expect(defaults.string(forKey: AccentTheme.storageKey) == "System Blue")
        #expect(AccentTheme.current == .blue)
    }
}

// MARK: - First-Frame Cover Lifecycle Tests

@Suite("FirstFrameCoverLifecycle", .serialized)
@MainActor
struct FirstFrameCoverLifecycleTests {
    @Test("PlayerSessionState defaults hasRenderedFirstFrame to false and updates cleanly")
    func sessionStateFirstFrameLifecycle() {
        let session = PlayerSessionState()
        #expect(!session.hasRenderedFirstFrame)

        session.hasRenderedFirstFrame = true
        #expect(session.hasRenderedFirstFrame)

        session.hasRenderedFirstFrame = false
        #expect(!session.hasRenderedFirstFrame)
    }

    @Test("PlayerViewModel hasRenderedFirstFrame resets across new sessions, stops, and handoffs, and clears outgoing stills on first frame")
    func playerViewModelFirstFrameLifecycle() {
        let vm = PlayerViewModel.shared
        defer {
            vm.error = nil
            vm.terminalOpenFailure = false
            vm.stop(reason: .ownerExit)
            vm.ownerKey = ""
            vm.activeSceneID = nil
            vm.clearAllOutgoingRouteStills()
        }

        vm.error = nil
        vm.terminalOpenFailure = false
        vm.stop(reason: .ownerExit)
        vm.ownerKey = ""
        vm.activeSceneID = nil
        vm.clearAllOutgoingRouteStills()
        #expect(!vm.hasRenderedFirstFrame)

        // Claiming a new owner starts with first frame unrendered; markFirstVideoFrameRendered reveals video
        // and clears any outgoing route still for that owner.
        let sceneA = UUID()
        let sceneB = UUID()
        let ownerA = "vod-first-frame-a"
        let ownerB = "vod-first-frame-b"
        vm.mode = .vod
        _ = vm.claimOwnerLease(owner: ownerA, sceneID: sceneA)
        #expect(!vm.hasRenderedFirstFrame)

        vm.outgoingRouteStills[ownerA] = makeSyntheticFrameImage()
        vm.resetPresentationGate()
        #expect(vm.outgoingRouteStill(for: ownerA) != nil)
        #expect(!vm.hasStartedPresenting)

        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        #expect(vm.outgoingRouteStill(for: ownerA) == nil)
        #expect(vm.hasStartedPresenting)

        // Internal reload preserves presentation continuity.
        vm.stop(reason: .internalReload)
        #expect(vm.hasRenderedFirstFrame)

        // Non-preserving teardowns reset hasRenderedFirstFrame so the next session shows cover until first frame.
        vm.stop(reason: .newContentOwnership)
        #expect(!vm.hasRenderedFirstFrame)

        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        vm.stop(reason: .ownerExit)
        #expect(!vm.hasRenderedFirstFrame)

        // Re-claiming the same owner in the same scene retains the running session; switching scene or owner resets it.
        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        let retainedLease = vm.claimOwnerLease(owner: ownerA, sceneID: sceneA)
        #expect(vm.hasRenderedFirstFrame)

        _ = vm.claimOwnerLease(owner: ownerA, sceneID: sceneB)
        #expect(!vm.hasRenderedFirstFrame)

        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        let leaseB = vm.claimOwnerLease(owner: ownerB, sceneID: sceneB)
        #expect(!vm.hasRenderedFirstFrame)
        #expect(!vm.isCurrentOwner(retainedLease, in: sceneA))

        // Portrait paging handoff resets hasRenderedFirstFrame for the incoming paged item.
        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        #expect(vm.beginPortraitPagingHandoff(lease: leaseB))
        #expect(!vm.hasRenderedFirstFrame)

        // Switching via claim(owner:) resets hasRenderedFirstFrame.
        vm.markFirstVideoFrameRendered()
        #expect(vm.hasRenderedFirstFrame)
        vm.claim(owner: ownerA)
        #expect(!vm.hasRenderedFirstFrame)

        // Error or terminal open failure prevents markFirstVideoFrameRendered from flipping true.
        vm.error = "Simulated error"
        vm.markFirstVideoFrameRendered()
        #expect(!vm.hasRenderedFirstFrame)

        vm.error = nil
        vm.terminalOpenFailure = true
        vm.markFirstVideoFrameRendered()
        #expect(!vm.hasRenderedFirstFrame)
    }
}

// MARK: - NativeMediaExportBackend Integration Tests

private struct MP4BoxInspection {
    let moovOffset: Int?
    let mdatOffset: Int?
    let moovBytes: Data

    func moovContainsFourCC(_ fourCC: String) -> Bool {
        guard let token = fourCC.data(using: .ascii) else { return false }
        return moovBytes.range(of: token) != nil
    }
}

private func inspectMP4Boxes(at url: URL) throws -> MP4BoxInspection {
    let data = try Data(contentsOf: url)
    var offset = 0
    var moovOffset: Int?
    var mdatOffset: Int?
    var moovBytes = Data()

    while offset + 8 <= data.count {
        let size32 = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let typeData = data.subdata(in: (offset + 4)..<(offset + 8))
        let type = String(data: typeData, encoding: .ascii) ?? ""

        let boxSize: Int
        if size32 == 0 {
            boxSize = data.count - offset
        } else if size32 == 1 {
            guard offset + 16 <= data.count else { break }
            let size64 = data.subdata(in: (offset + 8)..<(offset + 16)).withUnsafeBytes {
                UInt64(bigEndian: $0.load(as: UInt64.self))
            }
            boxSize = Int(min(size64, UInt64(data.count - offset)))
        } else {
            boxSize = Int(size32)
        }
        guard boxSize >= 8, offset + boxSize <= data.count else { break }

        if type == "moov" {
            moovOffset = offset
            moovBytes = data.subdata(in: offset..<(offset + boxSize))
        } else if type == "mdat" && mdatOffset == nil {
            mdatOffset = offset
        }
        offset += boxSize
    }
    return MP4BoxInspection(moovOffset: moovOffset, mdatOffset: mdatOffset, moovBytes: moovBytes)
}

private func writeSyntheticVideoTrack(
    to url: URL,
    width: Int = 320,
    height: Int = 240,
    frameCount: Int = 24,
    fps: Int32 = 30
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let fill = UInt8((index * 11) % 255)
            memset(base, Int32(fill), bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTime(value: CMTimeValue(index), timescale: fps)
        #expect(adaptor.append(buffer, withPresentationTime: pts))
    }

    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

private func writeSyntheticAudioTrack(
    to url: URL,
    sampleRate: Double = 44_100,
    durationSeconds: Double = 0.8
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    input.expectsMediaDataInRealTime = false
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    #expect(formatStatus == noErr)
    let desc = try #require(formatDescription)

    let totalFrames = Int(sampleRate * durationSeconds)
    let chunkFrames = 1024
    var writtenFrames = 0
    while writtenFrames < totalFrames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        let frames = min(chunkFrames, totalFrames - writtenFrames)
        let byteCount = frames * 4
        var samples = Data(count: byteCount)
        samples.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let t = Double(writtenFrames + i) / sampleRate
                let value = Int16(sin(2.0 * .pi * 440.0 * t) * 8000.0)
                ptr[i * 2] = value
                ptr[i * 2 + 1] = value
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        #expect(bbStatus == kCMBlockBufferNoErr)
        let block = try #require(blockBuffer)
        let copyStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        #expect(copyStatus == kCMBlockBufferNoErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(writtenFrames), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(sbStatus == noErr)
        let sb = try #require(sampleBuffer)
        #expect(input.append(sb))
        writtenFrames += frames
    }

    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Suite("NativeMediaExportBackend")
struct NativeMediaExportBackendTests {
    @Test("fittedDimensions and validResolutions enforce even dimensions without upscaling")
    func fittedResolutionCalculation() {
        #expect(NativeMediaExportBackend.fittedDimensions(width: 1920, height: 1080, resolution: .source) == (1920, 1080))
        #expect(NativeMediaExportBackend.fittedDimensions(width: 1920, height: 1080, resolution: .hd720) == (1280, 720))
        #expect(NativeMediaExportBackend.fittedDimensions(width: 1920, height: 1080, resolution: .hd1080) == (1920, 1080))
        #expect(NativeMediaExportBackend.fittedDimensions(width: 1920, height: 1080, resolution: .uhd4K) == (1920, 1080))
        #expect(NativeMediaExportBackend.fittedDimensions(width: 3840, height: 2160, resolution: .hd1080) == (1920, 1080))
        #expect(NativeMediaExportBackend.fittedDimensions(width: 1080, height: 1920, resolution: .hd720) == (720, 1280))
        #expect(NativeMediaExportBackend.validResolutions(width: 1920, height: 1080) == ExportResolution.allCases)
        // Extreme aspect ratio drops downscaled tiers whose minor edge collapses below 2px.
        let extreme = NativeMediaExportBackend.validResolutions(width: 10_000, height: 2)
        #expect(extreme == [.source])
    }

    @Test("Real probe, DASH remux, H.264/HEVC transcode with +faststart and hvc1, and O(1) validation succeed end-to-end")
    func endToEndNativeProbeRemuxAndTranscode() async throws {
        let workspace = try TempExportWorkspace()
        defer { workspace.cleanup() }

        let videoURL = workspace.sourceDirectory.appendingPathComponent("dash-video.m4s")
        let audioURL = workspace.sourceDirectory.appendingPathComponent("dash-audio.m4s")
        try await writeSyntheticVideoTrack(to: videoURL, width: 320, height: 240, frameCount: 24, fps: 30)
        try await writeSyntheticAudioTrack(to: audioURL, sampleRate: 44_100, durationSeconds: 0.8)

        let source = DownloadExportSource(
            downloadID: "dl-native-real",
            title: "Synthetic DASH Clip",
            videoURL: videoURL,
            audioURL: audioURL
        )
        let backend = NativeMediaExportBackend()

        // 1. Probe separate DASH video + audio tracks.
        let inventory = try await backend.probe(source: source, cancellation: ExportCancellation())
        #expect(inventory.width == 320)
        #expect(inventory.height == 240)
        #expect(inventory.duration > 0.5)
        #expect(inventory.videoCodec == "H.264")
        #expect(inventory.audioCodec == "AAC")
        #expect(inventory.canRemuxOriginal)
        #expect(!inventory.recipes.isEmpty)

        // 2. Remux (.original) dual-track DASH into a single faststart MP4.
        let remuxURL = workspace.exportRootDirectory.appendingPathComponent("remux.mp4")
        let remuxOptions = ExportOptions(
            filename: "remux",
            mode: .original,
            codec: .h264,
            resolution: .source,
            color: .sdr,
            includeAudio: true
        )
        let remuxResult = try await backend.execute(
            request: ExportNativeRequest(source: source, options: remuxOptions, output: remuxURL),
            cancellation: ExportCancellation(),
            progress: { _ in }
        )
        #expect(remuxResult.validated)

        let remuxBoxes = try inspectMP4Boxes(at: remuxURL)
        let remuxMoov = try #require(remuxBoxes.moovOffset)
        let remuxMdat = try #require(remuxBoxes.mdatOffset)
        #expect(remuxMoov < remuxMdat)
        #expect(remuxBoxes.moovContainsFourCC("avc1"))

        let remuxAsset = AVURLAsset(url: remuxURL)
        let remuxVideoTracks = try await remuxAsset.loadTracks(withMediaType: .video)
        let remuxAudioTracks = try await remuxAsset.loadTracks(withMediaType: .audio)
        #expect(remuxVideoTracks.count == 1)
        #expect(remuxAudioTracks.count == 1)

        // 3. Transcode H.264 (must be admitted and produce avc1 + faststart).
        #expect(inventory.recipes.contains(ExportRecipe(codec: .h264, resolution: .source, color: .sdr)))
        #expect(inventory.recipes.contains(ExportRecipe(codec: .h264, resolution: .hd720, color: .sdr)))
        let h264URL = workspace.exportRootDirectory.appendingPathComponent("transcode-h264.mp4")
        let h264Options = ExportOptions(
            filename: "transcode-h264",
            mode: .transcode,
            codec: .h264,
            resolution: .source,
            color: .sdr,
            includeAudio: true
        )
        let h264Result = try await backend.execute(
            request: ExportNativeRequest(source: source, options: h264Options, output: h264URL),
            cancellation: ExportCancellation(),
            progress: { _ in }
        )
        #expect(h264Result.validated)

        let h264Boxes = try inspectMP4Boxes(at: h264URL)
        let h264Moov = try #require(h264Boxes.moovOffset)
        let h264Mdat = try #require(h264Boxes.mdatOffset)
        #expect(h264Moov < h264Mdat)
        #expect(h264Boxes.moovContainsFourCC("avc1"))

        // 4. Transcode HEVC (verifying Apple native hvc1 tag + faststart) AND remux the HEVC output.
        #expect(inventory.recipes.contains(ExportRecipe(codec: .hevc, resolution: .source, color: .sdr)))
        #expect(inventory.recipes.contains(ExportRecipe(codec: .hevc, resolution: .hd1080, color: .sdr)))
        let hevcURL = workspace.exportRootDirectory.appendingPathComponent("transcode-hevc.mp4")
        let hevcOptions = ExportOptions(
            filename: "transcode-hevc",
            mode: .transcode,
            codec: .hevc,
            resolution: .source,
            color: .sdr,
            includeAudio: true
        )
        let hevcResult = try await backend.execute(
            request: ExportNativeRequest(source: source, options: hevcOptions, output: hevcURL),
            cancellation: ExportCancellation(),
            progress: { _ in }
        )
        #expect(hevcResult.validated)

        let hevcBoxes = try inspectMP4Boxes(at: hevcURL)
        let hevcMoov = try #require(hevcBoxes.moovOffset)
        let hevcMdat = try #require(hevcBoxes.mdatOffset)
        #expect(hevcMoov < hevcMdat)
        #expect(hevcBoxes.moovContainsFourCC("hvc1"))
        #expect(!hevcBoxes.moovContainsFourCC("hev1"))

        let hevcAsset = AVURLAsset(url: hevcURL)
        let hevcVideoTracks = try await hevcAsset.loadTracks(withMediaType: .video)
        let hevcAudioTracks = try await hevcAsset.loadTracks(withMediaType: .audio)
        #expect(hevcVideoTracks.count == 1)
        #expect(hevcAudioTracks.count == 1)

        // Remux the HEVC MP4 without audio to confirm remux preserves hvc1 and handles silent export.
        let hevcSource = DownloadExportSource(
            downloadID: "dl-hevc-remux",
            title: "HEVC Clip",
            videoURL: hevcURL,
            audioURL: nil
        )
        let hevcRemuxURL = workspace.exportRootDirectory.appendingPathComponent("remux-hevc.mp4")
        let hevcRemuxOptions = ExportOptions(
            filename: "remux-hevc",
            mode: .original,
            codec: .hevc,
            resolution: .source,
            color: .sdr,
            includeAudio: false
        )
        let hevcRemuxResult = try await backend.execute(
            request: ExportNativeRequest(source: hevcSource, options: hevcRemuxOptions, output: hevcRemuxURL),
            cancellation: ExportCancellation(),
            progress: { _ in }
        )
        #expect(hevcRemuxResult.validated)

        let hevcRemuxBoxes = try inspectMP4Boxes(at: hevcRemuxURL)
        let hevcRemuxMoov = try #require(hevcRemuxBoxes.moovOffset)
        let hevcRemuxMdat = try #require(hevcRemuxBoxes.mdatOffset)
        #expect(hevcRemuxMoov < hevcRemuxMdat)
        #expect(hevcRemuxBoxes.moovContainsFourCC("hvc1"))
        #expect(!hevcRemuxBoxes.moovContainsFourCC("hev1"))

        let hevcRemuxAsset = AVURLAsset(url: hevcRemuxURL)
        let hevcRemuxAudioTracks = try await hevcRemuxAsset.loadTracks(withMediaType: .audio)
        #expect(hevcRemuxAudioTracks.isEmpty)
    }
}
