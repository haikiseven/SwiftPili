import Foundation

extension DanmakuSegmentStore {
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if let error = error as? BiliError { return error.isCancellation }
        return false
    }

    /// `DanmakuAPI.segment` returns every status unjudged; a thrown
    /// `.httpError` can only come from a substituted `fetch`, and is still
    /// classified the way the response would have been.
    nonisolated static func failureKind(for error: any Error) -> DanmakuSegmentFailureKind {
        if case .httpError(let status, _)? = error as? BiliError {
            return status == 412 ? .riskControl(code: -412) : .http(status: status)
        }
        return .transport
    }

    nonisolated static func status(of error: any Error) -> String {
        if case .httpError(let status, _)? = error as? BiliError { return String(status) }
        return "-"
    }

    /// Off the main actor: 1.2 MB of protobuf and a sort. Measured at ~1.4 ms
    /// for the densest segment seen, which is a quarter of a frame — small, and
    /// still not something to spend on the actor that draws.
    nonisolated static func decode(
        _ data: Data,
        segmentIndex: Int
    ) async -> Result<DanmakuTimeIndex, DanmakuDecodeError> {
        await Task.detached(priority: .utility) {
            // `throws(…)` spelled out: inside this closure the compiler does not
            // infer the typed error of the `do` body and hands `catch` an
            // `any Error`, which a `Result<_, DanmakuDecodeError>` cannot hold.
            do throws(DanmakuDecodeError) {
                let elements = try DanmakuWireDecoder.decode(data, segmentIndex: segmentIndex)
                return .success(DanmakuTimeIndex(elements))
            } catch {
                return .failure(error)
            }
        }.value
    }
}
