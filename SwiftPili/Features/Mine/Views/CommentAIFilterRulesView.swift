import SwiftUI

struct CommentAIFilterRulesView: View {
    private let experiments = ExperimentalSettingsStore.shared
    let access: ExperimentalAccessReceipt

    @State private var newAccountKeyword = ""
    @State private var newContentKeyword = ""
    @State private var showResetConfirmation = false

    private var canMutate: Bool {
        experiments.storageError == nil && experiments.isCurrentAccess(access)
    }

    private func canResetRules(_ rules: CommentAIFilterRuleSet) -> Bool {
        !(rules.accountIdentityEnabled
            && rules.avatarBlueEnabled
            && rules.textPersonaEnabled
            && rules.lowLevelBoostEnabled
            && rules.customAccountKeywords.isEmpty
            && rules.customContentKeywords.isEmpty)
    }

    var body: some View {
        let rules = experiments.commentAIFilter.rules

        List {
            dimensionsSection(rules: rules)
            customAccountKeywordsSection(keywords: rules.customAccountKeywords)
            customContentKeywordsSection(keywords: rules.customContentKeywords)
            resetSection(rules: rules)

            if let storageError = experiments.storageError {
                Section {
                    Text(verbatim: storageError)
                        .foregroundStyle(.red)
                }
            } else if !experiments.isCurrentAccess(access) {
                Section {
                    Text("AI comment auto-filter is disabled in Experimental Features.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Detection Rules")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset all detection rules to default?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Rules", role: .destructive) {
                guard canMutate else { return }
                _ = experiments.updateCommentAIFilter {
                    let thresholdOverride = $0.rules.customThresholdOverride
                    $0.rules = .default
                    $0.rules.customThresholdOverride = thresholdOverride
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func dimensionsSection(rules: CommentAIFilterRuleSet) -> some View {
        Section("Built-in Rules") {
            Toggle(isOn: ruleBinding(get: { $0.accountIdentityEnabled }, set: { $0.accountIdentityEnabled = $1 })) {
                settingsLabel("Account & Bio", symbol: "person.text.rectangle")
            }
            .disabled(!canMutate)

            Toggle(isOn: ruleBinding(get: { $0.avatarBlueEnabled }, set: { $0.avatarBlueEnabled = $1 })) {
                settingsLabel("Whale-Blue Avatar", symbol: "photo.circle")
            }
            .disabled(!canMutate)

            Toggle(isOn: ruleBinding(get: { $0.textPersonaEnabled }, set: { $0.textPersonaEnabled = $1 })) {
                settingsLabel("AI Persona & Essays", symbol: "text.bubble")
            }
            .disabled(!canMutate)

            Toggle(isOn: ruleBinding(get: { $0.lowLevelBoostEnabled }, set: { $0.lowLevelBoostEnabled = $1 })) {
                settingsLabel("Low-Level Boost", symbol: "arrow.up.right.circle")
            }
            .disabled(!canMutate)
        }
    }

    private func customAccountKeywordsSection(keywords: [String]) -> some View {
        Section("Account Keywords") {
            HStack(spacing: AppSpacing.s) {
                TextField("Add username or bio keyword", text: $newAccountKeyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addAccountKeyword)
                    .disabled(!canMutate)
                Button("Add", action: addAccountKeyword)
                    .disabled(!canMutate || trimmed(newAccountKeyword).isEmpty)
            }
            ForEach(keywords, id: \.self) { keyword in
                Text(keyword)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            removeAccountKeyword(keyword)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(!canMutate)
                    }
            }
        }
    }

    private func customContentKeywordsSection(keywords: [String]) -> some View {
        Section("Comment Keywords") {
            HStack(spacing: AppSpacing.s) {
                TextField("Add comment text keyword", text: $newContentKeyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addContentKeyword)
                    .disabled(!canMutate)
                Button("Add", action: addContentKeyword)
                    .disabled(!canMutate || trimmed(newContentKeyword).isEmpty)
            }
            ForEach(keywords, id: \.self) { keyword in
                Text(keyword)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            removeContentKeyword(keyword)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(!canMutate)
                    }
            }
        }
    }

    private func resetSection(rules: CommentAIFilterRuleSet) -> some View {
        Section {
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label {
                    Text("Reset to Default Rules")
                        .foregroundStyle(.red)
                } icon: {
                    SettingsIcon(symbol: "arrow.counterclockwise", tint: .red)
                }
            }
            .disabled(!canMutate || !canResetRules(rules))
        }
    }

    private func addAccountKeyword() {
        let word = trimmed(newAccountKeyword)
        guard canMutate, !word.isEmpty else { return }
        _ = experiments.updateCommentAIFilter { config in
            let exists = config.rules.customAccountKeywords.contains {
                $0.caseInsensitiveCompare(word) == .orderedSame
            }
            if !exists {
                config.rules.customAccountKeywords.append(word)
            }
        }
        newAccountKeyword = ""
    }

    private func removeAccountKeyword(_ keyword: String) {
        guard canMutate else { return }
        _ = experiments.updateCommentAIFilter { config in
            config.rules.customAccountKeywords.removeAll { $0 == keyword }
        }
    }

    private func addContentKeyword() {
        let word = trimmed(newContentKeyword)
        guard canMutate, !word.isEmpty else { return }
        _ = experiments.updateCommentAIFilter { config in
            let exists = config.rules.customContentKeywords.contains {
                $0.caseInsensitiveCompare(word) == .orderedSame
            }
            if !exists {
                config.rules.customContentKeywords.append(word)
            }
        }
        newContentKeyword = ""
    }

    private func removeContentKeyword(_ keyword: String) {
        guard canMutate else { return }
        _ = experiments.updateCommentAIFilter { config in
            config.rules.customContentKeywords.removeAll { $0 == keyword }
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ruleBinding(
        get getter: @escaping (CommentAIFilterRuleSet) -> Bool,
        set setter: @escaping (inout CommentAIFilterRuleSet, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { getter(experiments.commentAIFilter.rules) },
            set: { value in
                guard canMutate else { return }
                _ = experiments.updateCommentAIFilter { setter(&$0.rules, value) }
            }
        )
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}
