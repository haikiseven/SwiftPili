import SwiftUI

struct CommentAIFilterSettingsView: View {
    private let experiments = ExperimentalSettingsStore.shared
    var access: ExperimentalAccessReceipt?

    private var isEnabled: Bool {
        experiments.isAllowed(.aiCommentFilter)
    }

    private var liveAccess: ExperimentalAccessReceipt? {
        if let access, experiments.isCurrentAccess(access) {
            return access
        }
        return experiments.captureAccess(.aiCommentFilter)
    }

    private var canMutate: Bool {
        experiments.storageError == nil && liveAccess != nil
    }

    var body: some View {
        let config = experiments.commentAIFilter
        let availability = CommentAIFilterAvailability.current

        List {
            Group {
                Section {
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { enabled in
                            guard experiments.storageError == nil else { return }
                            _ = experiments.setGranted(enabled, for: .aiCommentFilter)
                        }
                    )) {
                        settingsLabel("AI Comment Filter", symbol: "sparkle.magnifyingglass")
                    }
                    .disabled(experiments.storageError != nil)
                }

                if isEnabled {
                    Section {
                        Picker(selection: Binding(
                            get: { config.mode },
                            set: { mode in
                                guard canMutate else { return }
                                _ = experiments.updateCommentAIFilter { $0.mode = mode }
                            }
                        )) {
                            ForEach(CommentAIFilterMode.allCases) { mode in
                                Text(mode.localizedTitle).tag(mode)
                            }
                        } label: {
                            settingsLabel("Filter Mode", symbol: "line.3.horizontal.decrease.circle")
                        }
                        .disabled(!canMutate)

                        Picker(selection: Binding(
                            get: { config.sensitivitySelection },
                            set: { option in
                                guard canMutate else { return }
                                _ = experiments.updateCommentAIFilter { $0.sensitivitySelection = option }
                            }
                        )) {
                            ForEach(CommentAIFilterSensitivityOption.allCases) { option in
                                Text(option.localizedTitle).tag(option)
                            }
                        } label: {
                            settingsLabel("Sensitivity", symbol: "dial.medium")
                        }
                        .disabled(!canMutate)

                        if config.sensitivitySelection == .custom {
                            customThresholdSliderRow(effective: config.effectiveThreshold)
                        }
                    }

                    if availability.isAvailable {
                        Section {
                            onDeviceModelRefinerToggle(config: config, availability: availability)
                        }
                    } else {
                        Section {
                            onDeviceModelRefinerToggle(config: config, availability: availability)
                        } footer: {
                            Text(availability.localizedStatusText)
                        }
                    }

                    if let currentAccess = liveAccess {
                        Section {
                            NavigationLink {
                                CommentAIFilterRulesView(access: currentAccess)
                            } label: {
                                LabeledContent {
                                    Text(rulesSummary(for: config.rules))
                                        .monospacedDigit()
                                } label: {
                                    settingsLabel("Detection Rules", symbol: "checklist")
                                }
                            }

                            NavigationLink {
                                CommentAIFilterAllowlistView(access: currentAccess)
                            } label: {
                                LabeledContent {
                                    Text("\(config.allowedAuthorMIDs.count)")
                                        .monospacedDigit()
                                } label: {
                                    settingsLabel("Author Whitelist", symbol: "person.badge.shield.checkmark")
                                }
                            }
                        }
                    }
                }

                if let storageError = experiments.storageError {
                    Section {
                        Text(verbatim: storageError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("AI Comment Filter")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func onDeviceModelRefinerToggle(
        config: CommentAIFilterConfiguration,
        availability: CommentAIFilterAvailability
    ) -> some View {
        Toggle(isOn: Binding(
            get: { availability.isAvailable && config.foundationModelsRefinerEnabled },
            set: { enabled in
                guard canMutate else { return }
                _ = experiments.updateCommentAIFilter { $0.foundationModelsRefinerEnabled = enabled }
            }
        )) {
            settingsLabel("On-Device Model Refiner", symbol: "cpu")
        }
        .disabled(!availability.isAvailable || !canMutate)
    }

    private func customThresholdSliderRow(effective: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                settingsLabel("Custom Threshold", symbol: "slider.horizontal.3")
                Spacer()
                Text(verbatim: "\(effective)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(CommentAIFilterConfiguration.normalizedCustomThreshold(effective)) },
                    set: { value in
                        guard canMutate else { return }
                        let snapped = CommentAIFilterConfiguration.normalizedCustomThreshold(Int(value.rounded()))
                        _ = experiments.updateCommentAIFilter {
                            $0.rules.customThresholdOverride = snapped
                        }
                    }
                ),
                in: 30...90,
                step: 5
            ) {
                Text("Custom Threshold")
            }
            .disabled(!canMutate)
        }
    }

    private func rulesSummary(for rules: CommentAIFilterRuleSet) -> String {
        let base = "\(rules.activeDimensionCount)/4"
        if rules.customKeywordCount > 0 {
            return "\(base) (+\(rules.customKeywordCount))"
        }
        return base
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}
