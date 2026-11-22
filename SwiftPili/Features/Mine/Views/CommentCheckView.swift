import SwiftUI

struct CommentCheckView: View {
    private let experiments = ExperimentalSettingsStore.shared
    private let access: ExperimentalAccessReceipt
    @State private var check: CommentCheckOperation
    @State private var oid = ""
    @State private var message = ""

    init(access: ExperimentalAccessReceipt) {
        self.access = access
        _check = State(initialValue: CommentCheckOperation(access: access))
    }

    var body: some View {
        List {
            Section {
                TextField("Video AID", text: $oid)
                    .keyboardType(.numberPad)
                TextField("Comment text to post", text: $message, axis: .vertical)
                if !check.isChecking, let inputValidationMessage {
                    Text(inputValidationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("""
                Posts once, then checks anonymous public visibility. \
                A missing result is not a moderation verdict.
                """)
            }

            Section {
                Button("Post & Check") {
                    check.post(oid: oid, message: message)
                }
                .disabled(!check.canPost(oid: oid, message: message))

                if check.isChecking {
                    Button("Cancel", role: .cancel) { check.retire() }
                }
            }

            if let input = check.input {
                Section("Comment being checked") {
                    LabeledContent("Video AID", value: String(input.oid))
                    Text(verbatim: input.message)
                        .textSelection(.enabled)
                }
            }

            if let phase = check.phase {
                Section {
                    HStack {
                        ProgressView()
                        if phase == .posting {
                            Text("Posting comment…")
                        } else {
                            Text("Comment posted — verifying visibility…")
                        }
                    }
                    .accessibilityElement(children: .combine)
                } footer: {
                    Text("Stopping this check does not delete a posted comment.")
                }
            }

            if let result = check.result {
                resultSection(result)
            }

            if let storageError = experiments.storageError {
                Section { Text(verbatim: storageError).foregroundStyle(.secondary) }
            } else if !experiments.isCurrentAccess(access) {
                Section {
                    Text("""
                    Comment tools are unavailable for this session. \
                    Reopen this page after enabling them in settings.
                    """)
                        .foregroundStyle(.secondary)
                }
            }

            if !AuthManager.shared.isLoggedIn {
                Section {
                    Text("Login required to post comments")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Comment Check")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: experiments.isCurrentAccess(access)) { _, current in
            if !current { check.retire() }
        }
        .onChange(of: experiments.storageError) { _, error in
            if error != nil { check.retire() }
        }
        .onChange(of: AccountManager.shared.activeMid) { _, _ in check.retire() }
        .onChange(of: AuthManager.shared.isLoggedIn) { _, _ in check.retire() }
        .onDisappear { check.retire() }
    }

    private var inputValidationMessage: LocalizedStringKey? {
        let hasValidAID = Int(oid.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 > 0 } ?? false
        let hasComment = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch (hasValidAID, hasComment) {
        case (false, false): return "Please enter a positive video AID and comment before posting."
        case (false, true): return "Please enter a positive video AID before posting."
        case (true, false): return "Please enter comment text before posting."
        case (true, true): return nil
        }
    }

    private func resultSection(_ result: CommentCheckOperation.Result) -> some View {
        Section("Result") {
            HStack(alignment: .top) {
                Image(systemName: result.outcome.symbol)
                    .foregroundStyle(result.outcome == .visible ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    resultTitle(result.outcome)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    resultDescription(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let rpid = result.replyID {
                        Text(verbatim: "rpid: \(rpid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if check.canRetryVerification {
                Button("Retry visibility check") { check.retryVerification() }
                Text("Checks the same posted reply without sending another comment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultTitle(_ outcome: CommentCheckOperation.Outcome) -> some View {
        switch outcome {
        case .visible: Text("Comment is publicly visible")
        case .notFound: Text("Not found in this check")
        case .indeterminate: Text("Unable to determine visibility")
        case .submissionFailed: Text("Comment submission failed")
        }
    }

    @ViewBuilder
    private func resultDescription(_ result: CommentCheckOperation.Result) -> some View {
        switch result.outcome {
        case .visible:
            Text("The posted reply was found in an anonymous public query.")
        case .notFound:
            Text("""
            Completed public queries did not find this reply. Delays or limited query results may explain this; \
            it is not a moderation verdict.
            """)
        case .indeterminate:
            if result.replyID == nil {
                Text("""
                Submission was accepted without a usable reply ID, so visibility cannot be checked. \
                Do not resend just to retry verification.
                """)
            } else {
                Text("A public query could not be completed. Visibility is unknown.")
            }
        case .submissionFailed:
            Text("The request failed. The server may still have received the comment; check before posting again.")
            if let errorMessage = result.errorMessage {
                Text(verbatim: errorMessage)
            }
        }
    }
}
