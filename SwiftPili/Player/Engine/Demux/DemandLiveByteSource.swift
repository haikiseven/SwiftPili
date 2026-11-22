import Foundation

protocol DemandLiveByteSource: AnyObject, Sendable {
    func read(maximumBytes: Int, deadline: DispatchTime) throws -> Data?
    func cancel()
}

enum DemandLiveByteSourceFactory {
    static func make(kind: DemandLiveSourceKind, request: MediaOpenRequest) throws -> any DemandLiveByteSource {
        guard request.audioURL == nil else {
            throw MediaEngineError.demuxFailed("Demand live byte source requires muxed input")
        }
        guard DemandLiveHTTPTransport.isHTTPURL(request.videoURL) else {
            throw DemandLiveHTTPTransport.failure(.unsupportedURL)
        }
        switch kind {
        case .httpFLV: return DemandLiveFLVByteSource(request: request)
        case .hlsMPEGTS: return DemandLiveHLSByteSource(request: request)
        case .hlsFMP4, .progressiveFMP4:
            throw MediaEngineError.demuxFailed("Demand live byte source requires TS or FLV")
        }
    }
}

private final class DemandLiveFLVByteSource: DemandLiveByteSource, @unchecked Sendable {
    private let transport: DemandLiveHTTPTransport
    private let url: URL
    private var stream: DemandLiveHTTPTransport.Transfer?

    init(request: MediaOpenRequest) {
        self.url = request.videoURL
        self.transport = DemandLiveHTTPTransport(request: request)
    }

    func read(maximumBytes: Int, deadline: DispatchTime) throws -> Data? {
        try transport.checkCancellation()
        guard maximumBytes > 0 else { throw MediaEngineError.demuxFailed("FLV invalid read size") }
        if stream == nil { stream = try transport.start(url, body: .streaming) }
        guard let stream else { throw MediaEngineError.stopped }
        let data = try stream.transfer.read(maximumBytes: maximumBytes, task: stream.task, deadline: deadline)
        try transport.checkCancellation()
        return data
    }

    func cancel() { transport.cancel() }
}
