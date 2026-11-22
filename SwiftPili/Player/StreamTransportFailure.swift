import Foundation

/// Producer facts only. Scheduling and source authority belong to the player.
struct StreamTransportFailure: Error, Sendable, Equatable, LocalizedError {
    enum Stage: String, Sendable {
        case resolver, probe, mediaRead, mediaOpen, mediaSeek, mediaSupply
    }

    enum Reason: Sendable, Equatable {
        case url(Int)
        case http(Int)
    }

    let stage: Stage
    let reason: Reason
    let retryAfter: TimeInterval?
    var backendGeneration: UInt64?
    var sessionGeneration: UInt64?

    var isEligible: Bool {
        switch reason {
        case .url(let code):
            return [URLError.timedOut, .networkConnectionLost, .cannotFindHost,
                    .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
                .contains(URLError.Code(rawValue: code))
        case .http(let status):
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
    }

    var isCancellation: Bool { reason == .url(URLError.cancelled.rawValue) }

    var diagnostic: String {
        switch reason {
        case .url(let code): return "\(stage.rawValue):url:\(code)"
        case .http(let status): return "\(stage.rawValue):http:\(status)"
        }
    }

    var errorDescription: String? {
        switch reason {
        case .url(let code): return URLError(URLError.Code(rawValue: code)).localizedDescription
        case .http(let status): return "HTTP \(status)"
        }
    }

    static func http(_ response: HTTPURLResponse, stage: Stage) -> Self {
        Self(stage: stage, reason: .http(response.statusCode), retryAfter:
            [429, 503].contains(response.statusCode)
                ? HTTPRetryAfter.delay(response.value(forHTTPHeaderField: "Retry-After")) : nil)
    }

    static func preserving(_ error: any Error, stage: Stage) -> Self? {
        if var failure = error as? Self {
            failure = Self(stage: stage, reason: failure.reason, retryAfter: failure.retryAfter,
                backendGeneration: failure.backendGeneration, sessionGeneration: failure.sessionGeneration)
            return failure
        }
        if let engine = error as? MediaEngineError, case .transportFailed(let failure) = engine {
            return preserving(failure, stage: stage)
        }
        if let api = error as? BiliError {
            switch api {
            case .network(let underlying): return preserving(underlying, stage: stage)
            case .httpError(let status, let delay):
                return Self(stage: stage, reason: .http(status), retryAfter: delay)
            default: return nil
            }
        }
        if error is CancellationError {
            return Self(stage: stage, reason: .url(URLError.cancelled.rawValue), retryAfter: nil)
        }
        let underlying = error as NSError
        guard underlying.domain == NSURLErrorDomain else { return nil }
        return Self(stage: stage, reason: .url(underlying.code), retryAfter: nil)
    }

    func stamped(backend: UInt64, session: UInt64) -> Self {
        var copy = self
        copy.backendGeneration = backend
        copy.sessionGeneration = session
        return copy
    }
}

struct StreamProbeOutcome: Sendable {
    enum Rejection: String, Sendable {
        case structural, trustPolicy, unknown, cancelled
    }

    let host: String?
    let status: Int?
    let failure: StreamTransportFailure?
    let rejection: Rejection?

    var diagnostic: String {
        failure?.diagnostic ?? rejection?.rawValue ?? "reachable"
    }
}

struct StreamURLSelection: Sendable {
    let url: URL?
    let outcomes: [StreamProbeOutcome]
    let cancelled: Bool
    var failures: [StreamTransportFailure] { outcomes.compactMap(\.failure) }

    var eligibleFailure: StreamTransportFailure? {
        guard !cancelled, url == nil else { return nil }
        // Honor the longest server-directed delay among eligible candidates.
        return failures.filter(\.isEligible).max { ($0.retryAfter ?? 0) < ($1.retryAfter ?? 0) }
    }
}

@MainActor
final class StreamProbeEvidence {
    var outcomes: [StreamProbeOutcome] = []
}
