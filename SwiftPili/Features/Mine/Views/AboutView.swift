import SwiftUI
import UIKit

/// Settings → About: who made the app and exactly which build is running.
///
/// Label/value rows in an inset grouped list, like iOS Settings ▸ General ▸
/// About; values are selectable so a long press copies the commit for a bug
/// report. Design notes: `.trellis/tasks/11-02-about-screen/design.md`.
struct AboutView: View {
    private let info = AppBuildInfo.current

    var body: some View {
        List {
            headerSection
            Section {
                Text("Made by haikiseven. SwiftPili is a native BiliBili client inspired by PiliPlus.")
                if let piliPlus = URL(string: "https://github.com/bggRGjQaUbCoE/PiliPlus") {
                    Link(destination: piliPlus) {
                        Label {
                            Text(verbatim: "PiliPlus")
                        } icon: {
                            SettingsIcon(symbol: "arrow.up.right.square")
                        }
                    }
                }
            } header: {
                Text("Developer")
            }
            .listRowBackground(AppFill.card)
            versionSection
                .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                appIcon
                Text(verbatim: info.displayName)
                    .font(.title2.weight(.semibold))
                if let version = info.version {
                    Text(verbatim: version)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = info.iconNames.lazy.compactMap({ UIImage(named: $0) }).first {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var versionSection: some View {
        Section {
            valueRow("Version", value: info.version)
            valueRow("Build", value: info.build)
            LabeledContent("Commit") {
                if let commit = info.gitCommit {
                    HStack(spacing: 6) {
                        Text(verbatim: commit)
                            .monospaced()
                            .textSelection(.enabled)
                        if info.gitDirty == true {
                            Text("Modified")
                        }
                    }
                } else {
                    Text("Unknown")
                }
            }
            LabeledContent("Build Date") {
                if let date = info.buildDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .textSelection(.enabled)
                } else {
                    Text("Unknown")
                }
            }
        } header: {
            Text("Version")
        }
    }

    private func valueRow(_ title: LocalizedStringKey, value: String?) -> some View {
        LabeledContent(title) {
            if let value {
                Text(verbatim: value)
                    .textSelection(.enabled)
            } else {
                Text("Unknown")
            }
        }
    }
}
