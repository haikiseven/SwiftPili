import SwiftUI

/// Poll card (投票) shared by comment rows and dynamic feed posts.
///
/// Two states: BALLOT (radio/checkbox rows + a Vote button, respecting
/// the poll's choice count) before I have voted, RESULTS (proportional
/// accent bars, percentages, my choices ticked) once voted or after the
/// poll ends. State is fetched live per card — the embedding payloads
/// only carry id/title, and counts go stale the moment anyone votes.
struct VoteCardView: View {
    let voteId: Int
    var initialTitle: String?
    var initialJoinNum: Int?

    @State private var info: VoteInfo?
    @State private var selection: Set<Int> = []
    @State private var isSubmitting = false
    @State private var loadFailed = false
    @State private var errorText: String?

    private var isEnded: Bool {
        guard let end = info?.endTime, end > 0 else { return false }
        return TimeInterval(end) < Date().timeIntervalSince1970
    }

    private var maxChoices: Int { max(1, info?.choiceCnt ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption)
                    .foregroundStyle(Color.biliAccent)
                Text(info?.title ?? initialTitle ?? String(localized: "Poll"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Text("Poll")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.biliAccent.opacity(0.12))
                    .foregroundStyle(Color.biliAccent)
                    .clipShape(Capsule())
            }

            if let info {
                pollContent(info)
            } else if loadFailed {
                Text("Couldn't load poll")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Skeleton keeps the card height stable while loading.
                ForEach(0 ..< 2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: AppRadius.thumbnail)
                        .fill(.quaternary)
                        .frame(height: 34)
                }
            }

            if let errorText {
                Text(verbatim: errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .task(id: voteId) { await load() }
    }

    @ViewBuilder
    private func pollContent(_ info: VoteInfo) -> some View {
        let ended = isEnded
        let showsResults = !info.myVotes.isEmpty || ended
        let choices = max(1, info.choiceCnt ?? 1)
        // Multi-choice percentages prefer participants; single-choice always
        // uses the ballot sum. The footer separately preserves nonnil joinNum.
        let participantDenominator = choices > 1 ? info.joinNum.flatMap { $0 > 0 ? $0 : nil } : nil
        let participants = info.joinNum ?? initialJoinNum
        let needsBallotTotal = (showsResults && !info.options.isEmpty && participantDenominator == nil)
            || participants == nil
        let totalBallots = needsBallotTotal ? info.options.reduce(0) { $0 + ($1.cnt ?? 0) } : 0
        let denominator = participantDenominator ?? totalBallots

        ForEach(info.options) { option in
            if showsResults {
                resultRow(option, denominator: denominator)
            } else {
                ballotRow(option)
            }
        }
        footer(participants: participants ?? totalBallots, ended: ended,
               showsResults: showsResults, choices: choices)
    }

    // MARK: - Ballot mode

    private func ballotRow(_ option: VoteInfo.VoteOption) -> some View {
        let selected = selection.contains(option.idx)
        return Button {
            if selected {
                selection.remove(option.idx)
            } else if maxChoices == 1 {
                selection = [option.idx]
            } else if selection.count < maxChoices {
                selection.insert(option.idx)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.quaternary))
                Text(option.desc ?? "")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? AnyShapeStyle(Color.biliAccent.opacity(0.10)) : AnyShapeStyle(AppFill.nested),
                in: RoundedRectangle(cornerRadius: AppRadius.thumbnail)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results mode

    private func resultRow(_ option: VoteInfo.VoteOption, denominator: Int) -> some View {
        let count = option.cnt ?? 0
        let ratio = denominator > 0 ? min(1, Double(count) / Double(denominator)) : 0
        let mine = info?.myVotes.contains(option.idx) == true
        return HStack(spacing: 8) {
            Text(option.desc ?? "")
                .font(.footnote)
                .foregroundStyle(.primary)
            if mine {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.biliAccent)
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(Int((ratio * 100).rounded()))%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            // Proportional accent bar behind the row content.
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: AppRadius.thumbnail)
                    .fill(Color.biliAccent.opacity(mine ? 0.22 : 0.12))
                    .frame(width: max(proxy.size.width * ratio, 4))
            }
        }
        .background(AppFill.nested, in: RoundedRectangle(cornerRadius: AppRadius.thumbnail))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail))
    }

    @ViewBuilder
    private func footer(participants: Int, ended: Bool, showsResults: Bool, choices: Int) -> some View {
        HStack {
            Text("\(participants) joined")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if ended {
                Text("Poll ended")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !showsResults, choices > 1 {
                Text("Choose up to \(choices)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !showsResults {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Vote")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(selection.isEmpty ? Color.secondary : Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(
                                selection.isEmpty ? AnyShapeStyle(AppFill.inset) : AnyShapeStyle(Color.biliAccent),
                                in: Capsule()
                            )
                    }
                }
                .buttonStyle(.appControl)
                .disabled(selection.isEmpty || isSubmitting)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Data

    private func load() async {
        guard info == nil else { return }
        do {
            let fetched = try await VoteAPI.getInfo(voteId: voteId)
            info = fetched
            PlayerLog.log("[Vote] loaded \(voteId): \"\(fetched.title ?? "?")\" options=\(fetched.options.count) joined=\(fetched.joinNum ?? -1) myVotes=\(fetched.myVotes)")
        } catch {
            loadFailed = true
            PlayerLog.log("[Vote] ⚠️ load \(voteId) failed on BOTH endpoints: \(error)")
        }
    }

    private func submit() async {
        guard !selection.isEmpty, !isSubmitting else { return }
        guard AuthManager.shared.isLoggedIn else {
            errorText = String(localized: "Login required")
            return
        }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            try await VoteAPI.vote(voteId: voteId, choices: Array(selection))
            // Refetch for authoritative counts + my_votes → results mode.
            info = nil
            loadFailed = false
            await load()
        } catch {
            errorText = String(format: String(localized: "Vote failed: %@"), error.localizedDescription)
            PlayerLog.log("[Vote] ⚠️ submit \(voteId) choices=\(selection.sorted()) failed: \(error)")
        }
    }
}
