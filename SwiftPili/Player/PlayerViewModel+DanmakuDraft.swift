import AVFoundation
import Foundation
import UIKit

extension PlayerViewModel {

    func openFullscreenDanmakuDraft(
        presentation: PlayerPresentationReceipt,
        hostIdentity: UUID
    ) -> (receipt: FullscreenDanmakuDraftReceipt, text: String)? {
        guard case .vod = presentation.context.source,
              isCurrentPresentationReceipt(presentation, hostIdentity: hostIdentity),
              AuthManager.shared.isLoggedIn else { return nil }
        let retained = fullscreenVODDanmakuDraft
        let text = retained.flatMap { isCurrentFullscreenDanmakuDraft($0.receipt) ? $0.text : nil } ?? ""
        let receipt = FullscreenDanmakuDraftReceipt(
            presentation: presentation, accountSession: AuthManager.shared.sessionGeneration
        )
        fullscreenVODDanmakuDraft = FullscreenDanmakuDraft(receipt: receipt)
        fullscreenVODDanmakuSendFailure = nil
        return (receipt, text)
    }

    /// Native host identity is intentionally absent: a pending send may finish after that host is gone.
    func isCurrentFullscreenDanmakuDraft(_ receipt: FullscreenDanmakuDraftReceipt) -> Bool {
        guard fullscreenVODDanmakuDraft?.receipt == receipt,
              AuthManager.shared.isLoggedIn,
              AuthManager.shared.sessionGeneration == receipt.accountSession,
              let presentation = fullscreenPresentation else { return false }
        return isCurrentPresentation(presentation, receipt: receipt.presentation)
    }

    @discardableResult
    func retainFullscreenDanmakuDraft(_ text: String, receipt: FullscreenDanmakuDraftReceipt) -> Bool {
        guard isCurrentFullscreenDanmakuDraft(receipt),
              fullscreenVODDanmakuDraft?.isDiscarded == false else { return false }
        fullscreenVODDanmakuDraft?.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    func discardFullscreenDanmakuDraft(receipt: FullscreenDanmakuDraftReceipt) {
        guard isCurrentFullscreenDanmakuDraft(receipt) else { return }
        fullscreenVODDanmakuDraft?.text = ""
        // Keep the receipt so a pending failure may still notify this source,
        // but never restore explicitly discarded text. Reopen replaces it.
        fullscreenVODDanmakuDraft?.isDiscarded = true
    }

    func handOffFullscreenDanmakuFailure(_ message: String, receipt: FullscreenDanmakuDraftReceipt) {
        guard isCurrentFullscreenDanmakuDraft(receipt) else { return }
        fullscreenVODDanmakuSendFailure = FullscreenDanmakuFailure(receipt: receipt, message: message)
    }

    func takeFullscreenDanmakuFailure(ownerLease: PlayerOwnerLease?) -> String? {
        guard let failure = fullscreenVODDanmakuSendFailure,
              ownerLease == failure.receipt.presentation.context.ownerLease,
              isCurrentFullscreenDanmakuDraft(failure.receipt) else { return nil }
        fullscreenVODDanmakuSendFailure = nil
        return failure.message
    }

    func retireFullscreenDanmakuDraft() {
        fullscreenVODDanmakuDraft = nil
        fullscreenVODDanmakuSendFailure = nil
    }

    /// Nil on success. A non-nil string is the toast, already localized.
    /// Empty text is not a failure. Does not retry, and does not release the store.
    func sendDanmaku(text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard danmakuServerAllowsVisibleWork else { return String(localized: "Couldn't send danmaku") }
        guard DanmakuFeatureGate.isEnabled(), mode == .vod,
              let cid = currentCid, let bvid = currentBvid else {
            return String(localized: "Couldn't send danmaku")
        }
        let progressTime = danmakuTransportTime
        do {
            let result = try await DanmakuAPI.postDanmaku(
                oid: cid,
                bvid: bvid,
                message: trimmed,
                progress: Int((progressTime * 1000).rounded())
            )
            // The post already landed. A part switch during the await must not
            // paint this bullet on the next video, and it is not a send error.
            guard mode == .vod, currentCid == cid else { return nil }
            // Where the picture is NOW, not where it was before the round trip: the bullet enters at the
            // current position, paused or not.
            echoDanmaku(DanmakuElem(
                id: danmakuEchoID(result),
                progress: danmakuTransportTime,
                mode: 1,
                fontSize: 25,
                color: 0xFF_FF_FF,
                midHash: "",
                content: trimmed,
                idStr: result.dmidStr ?? ""
            ))
            return nil
        } catch {
            return DanmakuSendFailure.message(for: error)
        }
    }

    /// Server `dmid` when the post returned one. Zero and nil both collide on
    /// `live[0]`, so a missing id gets its own negative key.
    private func danmakuEchoID(_ result: PostDanmakuResult) -> Int64 {
        if let resolved = result.resolvedID { return resolved }
        let id = nextDanmakuEchoID
        if nextDanmakuEchoID > Int64.min {
            nextDanmakuEchoID -= 1
        }
        return id
    }
}
