import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct CommentAIRefinementInput: Sendable {
    let rpid: Int
    let authorName: String
    let authorLevel: Int?
    let authorSign: String?
    let message: String
    let stage1: CommentAIAssessment
}

enum CommentAIFoundationRefiner {
    static func refine(_ input: CommentAIRefinementInput) async -> CommentAIAssessment? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !Task.isCancelled else { return nil }

        do {
            return try await CommentAIFoundationRefinerGate.shared.run {
                try await performInference(input)
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func performInference(
        _ input: CommentAIRefinementInput
    ) async throws -> CommentAIAssessment? {
        try Task.checkCancellation()
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let instructions = """
        You classify Bilibili comments to detect automated AI-bot accounts
        ("大肥鱼" / DeepSeek Agent / 鲸鱼娘 bots and LLM comment-farming).
        Key cues: usernames/bios with 大肥鱼, DeepSeek, の鲸, AI代管, Agent, Token;
        self-references like 本鲸/本鱼; roleplay actions like (摇尾巴)/(吃白饭);
        @owner mentions; or formulaic Markdown/recap essays.
        Give normal human comments low scores (< 40) and clear AI bots high scores (>= 65).
        """
        let session = LanguageModelSession(instructions: instructions)
        let clippedMessage = String(input.message.prefix(420))
        let clippedSign = String((input.authorSign ?? "").prefix(120))
        let levelText = input.authorLevel.map { "Lv\($0)" } ?? "unknown"
        let stage1Summary = input.stage1.reasons.isEmpty
            ? "none"
            : input.stage1.reasons.joined(separator: "; ")

        let prompt = """
        Author: \(input.authorName) (\(levelText))
        Bio: \(clippedSign.isEmpty ? "(empty)" : clippedSign)
        Offline heuristic score: \(input.stage1.score)/100 (signals: \(stage1Summary))
        Comment:
        \(clippedMessage)
        """

        let response = try await session.respond(to: prompt, generating: CommentAIRefinementVerdict.self)
        try Task.checkCancellation()

        let modelScore = max(0, min(100, response.content.aiProbability))
        let blended = max(0, min(100, (input.stage1.score * 35 + modelScore * 65) / 100))

        var reasons = input.stage1.reasons
        let trimmedReason = response.content.shortReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReason.isEmpty {
            let formatted = String(localized: "On-device model: \(trimmedReason)")
            reasons.insert(formatted, at: 0)
        }
        return CommentAIAssessment(
            score: blended,
            reasons: Array(reasons.prefix(4)),
            stage: .refined
        )
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct CommentAIRefinementVerdict {
    @Guide(description: "Integer score 0-100 estimating likelihood that this Bilibili comment is AI-bot generated.")
    var aiProbability: Int

    @Guide(description: "One concise reason (under 24 characters) in Chinese summarizing the verdict.")
    var shortReason: String
}
#endif

private actor CommentAIFoundationRefinerGate {
    static let shared = CommentAIFoundationRefinerGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isBusy {
            isBusy = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await self.waitForSlot(id: waiterID)
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func waitForSlot(id waiterID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            if !isBusy {
                isBusy = true
                continuation.resume()
                return
            }
            waiters.append(Waiter(id: waiterID, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
            return
        }
        isBusy = false
    }
}
