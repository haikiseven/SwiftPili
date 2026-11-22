import Foundation
import Observation

@MainActor
@Observable
final class QRCodeLoginViewModel {
    enum State: Equatable {
        case idle
        case loading
        case ready(url: String, qrcodeKey: String)
        case scanning
        case confirmed
        case expired
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loginSession: QRCodeLoginSession?
    @ObservationIgnored private var attemptID: UUID?

    nonisolated deinit {
        pollTask?.cancel()
        loginSession?.invalidate()
    }

    func generateQRCode() async {
        guard !Task.isCancelled else { return }
        retireAttempt()
        let attemptID = UUID()
        let session = QRCodeLoginSession()
        self.attemptID = attemptID
        loginSession = session
        state = .loading
        do {
            let result = try await session.generateQRCode()
            try Task.checkCancellation()
            guard isCurrent(attemptID) else { return }
            state = .ready(url: result.url, qrcodeKey: result.qrcodeKey)
            startPolling(qrcodeKey: result.qrcodeKey, attemptID: attemptID, session: session)
        } catch {
            guard isCurrent(attemptID) else { return }
            publishFailure(error)
            finishAttempt(attemptID)
        }
    }

    func cancel() {
        retireAttempt()
        state = .idle
    }

    private func startPolling(qrcodeKey: String, attemptID: UUID, session: QRCodeLoginSession) {
        pollTask = Task { [weak self] in
            defer { self?.finishAttempt(attemptID) }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    guard self?.isCurrent(attemptID) == true else { return }
                    let result = try await session.poll(qrcodeKey: qrcodeKey)
                    try Task.checkCancellation()
                    guard let self, self.isCurrent(attemptID) else { return }
                    switch result {
                    case .confirmed(let credentials):
                        self.handleLogin(credentials)
                        return
                    case .expired:
                        self.state = .expired
                        return
                    case .scanning:
                        self.state = .scanning
                    case .waiting:
                        break
                    }
                }
            } catch {
                guard let self, self.isCurrent(attemptID) else { return }
                self.publishFailure(error)
            }
        }
    }

    private func handleLogin(_ credentials: QRLoginCredentials) {
        AuthManager.shared.loginWithCookies(
            sessData: credentials.sessData,
            biliJct: credentials.biliJct,
            dedeUserID: credentials.dedeUserID,
            ckMd5: credentials.ckMd5
        )
        state = .confirmed
    }

    private func isCurrent(_ attemptID: UUID) -> Bool {
        self.attemptID == attemptID
    }

    private func publishFailure(_ error: Error) {
        if Task.isCancelled || BiliAPIRetryPolicy.isCancellation(error)
            || (error as? BiliError)?.isCancellation == true {
            state = .idle
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    private func finishAttempt(_ attemptID: UUID) {
        guard isCurrent(attemptID) else { return }
        retireAttempt()
    }

    private func retireAttempt() {
        attemptID = nil
        pollTask?.cancel()
        pollTask = nil
        loginSession?.invalidate()
        loginSession = nil
    }
}
