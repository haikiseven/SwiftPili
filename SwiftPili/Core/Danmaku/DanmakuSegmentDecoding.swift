import Foundation

extension DanmakuSegmentStore {
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if let error = error as? BiliError { return error.isCancellation }
        return false
    }

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

    nonisolated static func decode(
        _ data: Data,
        segmentIndex: Int
    ) async -> Result<DanmakuTimeIndex, DanmakuDecodeError> {
        await Task.detached(priority: .utility) {
            do throws(DanmakuDecodeError) {
                let elements = try DanmakuWireDecoder.decode(data, segmentIndex: segmentIndex)
                return .success(DanmakuTimeIndex(elements))
            } catch {
                return .failure(error)
            }
        }.value
    }
}
