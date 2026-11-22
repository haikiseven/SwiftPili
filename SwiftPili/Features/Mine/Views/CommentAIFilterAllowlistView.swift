import SwiftUI

struct CommentAIFilterAllowlistView: View {
    private let experiments = ExperimentalSettingsStore.shared
    var access: ExperimentalAccessReceipt?
    @State private var showClearConfirmation = false

    private var canMutate: Bool {
        experiments.storageError == nil
            && (access.map { experiments.isCurrentAccess($0) } ?? experiments.isAllowed(.aiCommentFilter))
    }

    private var authors: [(mid: Int, name: String?)] {
        experiments.commentAIFilter.sortedAllowedAuthors
    }

    var body: some View {
        List {
            if authors.isEmpty {
                ContentUnavailableView(
                    "No Whitelisted Authors",
                    systemImage: "checkmark.shield",
                    description: Text(
                        "Expand a collapsed comment and tap its AI badge to inspect signals or add its author here."
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(authors, id: \.mid) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name ?? "MID \(entry.mid)")
                                .font(.body)
                            Text("MID \(entry.mid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                guard canMutate else { return }
                                _ = experiments.removeCommentAIFilterAllowedAuthor(mid: entry.mid)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!canMutate)
                        }
                    }
                } header: {
                    Text("\(authors.count) Whitelisted Authors")
                } footer: {
                    Text("Swipe left on an author to remove them from the local whitelist.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label {
                            Text("Clear Whitelist")
                                .foregroundStyle(.red)
                        } icon: {
                            SettingsIcon(symbol: "trash", tint: .red)
                        }
                    }
                    .disabled(!canMutate)
                }
            }

            if let storageError = experiments.storageError {
                Section {
                    Text(verbatim: storageError)
                        .foregroundStyle(.red)
                }
            } else if !canMutate {
                Section {
                    Text("AI comment auto-filter is disabled in Experimental Features.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(AppFill.card)
        .readableFormWidth()
        .accentContentBoundary()
        .navigationTitle("Author Whitelist")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear all whitelisted authors?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Whitelist", role: .destructive) {
                guard canMutate else { return }
                _ = experiments.clearCommentAIFilterAllowlist()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
