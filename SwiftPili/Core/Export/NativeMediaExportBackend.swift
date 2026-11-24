import Foundation
#if canImport(CMediaExport)
import CMediaExport

final class NativeMediaExportBackend: DownloadExportNativeBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.swiftpili.export.native", qos: .userInitiated)

    func probe(source: DownloadExportSource, cancellation: ExportCancellation) async throws -> ExportMediaInventory {
        let facts = try await inspect(source: source, cancellation: cancellation)
        let colors: [ExportColorMode] = facts.hdr ? [.sourceHDR, .sdr] : [.sdr]
        let validResolutions = Self.validResolutions(width: facts.width, height: facts.height)
        var recipes: [ExportRecipe] = []
        for codec in ExportVideoCodec.allCases {
            for color in colors where color != .sourceHDR || codec == .hevc {
                let options = ExportOptions(
                    filename: "admission",
                    mode: .transcode,
                    codec: codec,
                    resolution: .source,
                    color: color,
                    includeAudio: facts.audioCodec != nil
                )
                if try await admits(source: source, options: options, cancellation: cancellation) {
                    for resolution in validResolutions {
                        recipes.append(ExportRecipe(codec: codec, resolution: resolution, color: color))
                    }
                }
            }
        }
        let original = ExportOptions(
            filename: "admission",
            mode: .original,
            codec: .hevc,
            resolution: .source,
            color: .sourceHDR,
            includeAudio: facts.audioCodec != nil
        )
        let remux = try await admits(source: source, options: original, cancellation: cancellation)
        return ExportMediaInventory(
            width: facts.width,
            height: facts.height,
            duration: facts.duration,
            videoCodec: facts.videoCodec,
            audioCodec: facts.audioCodec,
            hdr: facts.hdr,
            dolbyVisionProfile: facts.dolbyVisionProfile,
            recipes: recipes,
            canRemuxOriginal: remux,
            estimatedOutputBytes: nil
        )
    }

    static func fittedDimensions(width: Int, height: Int, resolution: ExportResolution) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let w = Double(width)
        let h = Double(height)
        let scale: Double
        switch resolution {
        case .source:
            scale = 1.0
        case .hd720:
            scale = min(1.0, 1280.0 / max(w, h), 720.0 / min(w, h))
        case .hd1080:
            scale = min(1.0, 1920.0 / max(w, h), 1080.0 / min(w, h))
        case .uhd4K:
            scale = min(1.0, 3840.0 / max(w, h), 2160.0 / min(w, h))
        }
        let outW = (Int(w * scale) / 2) * 2
        let outH = (Int(h * scale) / 2) * 2
        return (outW, outH)
    }

    static func validResolutions(width: Int, height: Int) -> [ExportResolution] {
        ExportResolution.allCases.filter { resolution in
            let size = fittedDimensions(width: width, height: height, resolution: resolution)
            return size.width >= 2 && size.height >= 2
        }
    }

    private func inspect(
        source: DownloadExportSource, cancellation: ExportCancellation
    ) async throws -> ExportMediaInventory {
        let options = ExportOptions(
            filename: "probe",
            mode: .original,
            codec: .hevc,
            resolution: .source,
            color: .sourceHDR,
            includeAudio: true
        )
        return try await perform(
            source: source,
            options: options,
            output: URL(fileURLWithPath: "/dev/null"),
            cancellation: cancellation
        ) { job in
            var info = me_export_inventory()
            try Self.check(me_export_job_probe(job, &info), job: job)
            let hdr = info.color_transfer == 16 || info.color_transfer == 18 || info.dolby_vision_profile > 0
            return ExportMediaInventory(
                width: Int(info.width),
                height: Int(info.height),
                duration: Double(info.duration_microseconds) / 1_000_000,
                videoCodec: Self.displayCodecName(for: info.video_codec_id),
                audioCodec: info.has_audio != 0 ? Self.displayCodecName(for: info.audio_codec_id) : nil,
                hdr: hdr,
                dolbyVisionProfile: info.dolby_vision_profile > 0 ? Int(info.dolby_vision_profile) : nil,
                recipes: [],
                canRemuxOriginal: false,
                estimatedOutputBytes: nil
            )
        }
    }

    private static func displayCodecName(for codecID: Int32) -> String {
        guard let raw = me_export_codec_name(codecID) else {
            return String(codecID)
        }
        let name = String(cString: raw)
        switch name.lowercased() {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        default: return name.uppercased()
        }
    }

    private func admits(
        source: DownloadExportSource, options: ExportOptions, cancellation: ExportCancellation
    ) async throws -> Bool {
        try await perform(
            source: source,
            options: options,
            output: URL(fileURLWithPath: "/dev/null"),
            cancellation: cancellation
        ) { job in
            let result = me_export_job_check_capability(job)
            if result == ME_EXPORT_CANCELLED { throw ExportFailure.cancelled }
            return result == ME_EXPORT_OK
        }
    }

    func execute(
        request: ExportNativeRequest, cancellation: ExportCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportNativeResult {
        _ = try await perform(
            source: request.source,
            options: request.options,
            output: request.output,
            cancellation: cancellation
        ) { job in
            let box = NativeProgressBox(progress)
            let retained = Unmanaged.passRetained(box)
            defer { retained.release() }
            let result = me_export_job_execute(job, { context, value in
                guard let context, let value else { return }
                let box = Unmanaged<NativeProgressBox>.fromOpaque(context).takeUnretainedValue()
                if value.pointee.duration_seconds > 0 {
                    box.callback(value.pointee.processed_seconds / value.pointee.duration_seconds)
                }
            }, retained.toOpaque())
            try Self.check(result, job: job)
            try Self.check(me_export_job_validate_output(job), job: job)
            return true
        }
        return ExportNativeResult(validated: true)
    }

    private func perform<T: Sendable>(
        source: DownloadExportSource, options: ExportOptions, output: URL,
        cancellation: ExportCancellation, body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw ExportFailure.cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard me_export_abi_version() == 1 else { throw ExportFailure.backendUnavailable }
                    guard !cancellation.isCancelled else { throw ExportFailure.cancelled }
                    guard source.filesExist else { throw ExportFailure.sourceUnavailable }
                    let result = try source.videoURL.path.withCString { video in
                        try (source.audioURL?.path ?? "").withCString { audio in
                            try output.path.withCString { destination in
                                var raw = me_export_options()
                                raw.video_path = video
                                raw.audio_path = source.audioURL == nil ? nil : audio
                                raw.output_path = destination
                                raw.include_audio = options.includeAudio ? 1 : 0
                                raw.mode = options.mode == .original ? ME_EXPORT_REMUX
                                    : (options.codec == .h264 ? ME_EXPORT_H264 : ME_EXPORT_HEVC)
                                raw.color = options.color == .sdr
                                    ? ME_EXPORT_COLOR_SDR : ME_EXPORT_COLOR_SOURCE
                                switch options.resolution {
                                case .source: break
                                case .hd720:
                                    raw.maximum_long_edge = 1280
                                    raw.maximum_short_edge = 720
                                    raw.resolution_tier = 720
                                case .hd1080:
                                    raw.maximum_long_edge = 1920
                                    raw.maximum_short_edge = 1080
                                    raw.resolution_tier = 1080
                                case .uhd4K:
                                    raw.maximum_long_edge = 3840
                                    raw.maximum_short_edge = 2160
                                    raw.resolution_tier = 2160
                                }
                                guard let job = me_export_job_create(&raw) else {
                                    throw ExportFailure.backendUnavailable
                                }
                                let cancelHandle = NativeCancelHandle(job)
                                cancellation.install { cancelHandle.cancel() }
                                defer {
                                    cancellation.uninstall()
                                    cancelHandle.close()
                                    me_export_job_destroy(job)
                                }
                                guard !cancellation.isCancelled else { throw ExportFailure.cancelled }
                                return try body(job)
                            }
                        }
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func check(_ result: me_export_result, job: OpaquePointer) throws {
        if result == ME_EXPORT_CANCELLED { throw ExportFailure.cancelled }
        guard result == ME_EXPORT_OK else {
            let rawMessage = me_export_job_error(job)
                .map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let message = (rawMessage?.isEmpty == false) ? rawMessage! : String(localized: "Export failed")
            throw ExportFailure.native(message)
        }
    }
}

private final class NativeProgressBox: @unchecked Sendable {
    let callback: @Sendable (Double) -> Void
    init(_ callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
}

private final class NativeCancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var job: OpaquePointer?
    init(_ job: OpaquePointer) { self.job = job }
    func cancel() { lock.lock(); defer { lock.unlock() }; if let job { me_export_job_cancel(job) } }
    func close() { lock.lock(); defer { lock.unlock() }; job = nil }
}
#else
struct NativeMediaExportBackend: DownloadExportNativeBackend {
    func probe(source: DownloadExportSource, cancellation: ExportCancellation) async throws -> ExportMediaInventory {
        throw ExportFailure.backendUnavailable
    }
    func execute(
        request: ExportNativeRequest, cancellation: ExportCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportNativeResult {
        throw ExportFailure.backendUnavailable
    }
}
#endif
