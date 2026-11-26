import SwiftUI

struct SponsorBlockSettingsView: View {
    @Bindable private var manager = SponsorBlockManager.shared
    @State private var serverDraft = SponsorBlockManager.shared.customServer
    @State private var userIDDraft = SponsorBlockManager.shared.privateUserID
    @State private var showResetStats = false

    var body: some View {
        List {
            Group {
                masterSection
                categoriesSection
                filteringSection
                displaySection
                statsSection
                contributionSection
                serverSection
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("SponsorBlock")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Master

    private var masterSection: some View {
        Section {
            Toggle(isOn: $manager.isEnabled) {
                Label {
                    // Disambiguates master toggle from "SponsorBlock" title/menu labels in zh-Hans.
                    Text("Enable SponsorBlock")
                } icon: {
                    SettingsIcon(symbol: "shield.lefthalf.filled")
                }
            }
        }
    }

    // MARK: Categories

    private var categoriesSection: some View {
        Section {
            ForEach(SponsorCategory.allCases) { category in
                Picker(selection: Binding(
                    get: { manager.action(for: category) },
                    set: { manager.setAction($0, for: category) }
                )) {
                    ForEach(SponsorAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                            .fill(category.color)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: AppStroke.hairlineWidth)
                            )
                            .frame(width: 14, height: 14)
                        Text(category.displayName)
                    }
                }
            }
        } header: {
            Text("Categories")
        }
    }

    // MARK: Filtering

    private var filteringSection: some View {
        Section {
            Picker(selection: $manager.minVotes) {
                Text("Include Down-voted").tag(-1)
                Text("Hide Down-voted").tag(0)
                Text("Only Up-voted").tag(1)
            } label: {
                Label {
                    Text("Segment Score")
                } icon: {
                    SettingsIcon(symbol: "hand.thumbsup")
                }
            }
        } header: {
            Text("Filtering")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle(isOn: $manager.showOnProgressBar) {
                Label {
                    Text("Show on Progress Bar")
                } icon: {
                    SettingsIcon(symbol: "chart.bar")
                }
            }
            Toggle(isOn: $manager.showSkipNotice) {
                Label {
                    Text("Skip Notice")
                } icon: {
                    SettingsIcon(symbol: "bell.badge")
                }
            }
        } header: {
            Text("Display")
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        Section {
            LabeledContent {
                Text("\(manager.skippedCount)")
                    .monospacedDigit()
            } label: {
                Label {
                    Text("Segments Skipped")
                } icon: {
                    SettingsIcon(symbol: "forward")
                }
            }
            LabeledContent {
                Text(FormatUtils.duration(Int(manager.skippedSeconds)))
                    .monospacedDigit()
            } label: {
                Label {
                    Text("Time Saved")
                } icon: {
                    SettingsIcon(symbol: "clock.arrow.circlepath")
                }
            }
            Button(role: .destructive) {
                showResetStats = true
            } label: {
                Label {
                    Text("Reset Statistics")
                        .foregroundStyle(.red)
                } icon: {
                    SettingsIcon(symbol: "arrow.counterclockwise", tint: .red)
                }
            }
            .confirmationDialog(
                "Reset skip statistics?",
                isPresented: $showResetStats,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { manager.resetStats() }
            }
        } header: {
            Text("Statistics")
        }
    }

    // MARK: Contribution

    private var contributionSection: some View {
        Section {
            HStack {
                Label {
                    Text("User ID")
                } icon: {
                    SettingsIcon(symbol: "person.text.rectangle")
                }
                Spacer()
                TextField("Auto-generated", text: $userIDDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                    .onSubmit { commitUserID() }
            }
        } header: {
            Text("Contribution")
        }
    }

    private func commitUserID() {
        let trimmed = userIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.privateUserID = trimmed
        userIDDraft = trimmed
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            HStack {
                Label {
                    Text("Server")
                } icon: {
                    SettingsIcon(symbol: "server.rack")
                }
                Spacer()
                TextField("https://bsbsb.top", text: $serverDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(.secondary)
                    .onSubmit { commitServer() }
            }
        } header: {
            Text("Custom Server")
        }
    }

    private func commitServer() {
        let trimmed = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.customServer = trimmed
        serverDraft = trimmed
    }
}
