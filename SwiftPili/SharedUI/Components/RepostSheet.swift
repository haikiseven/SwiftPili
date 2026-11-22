import SwiftUI

// MARK: - Repost

/// Repost composer for one Moment: optional added text over a quote of
/// the original post. Presented from the Moments feed, a moment's
/// detail page, and the Moments tab of a user's profile.
struct RepostSheet: View {
    let item: DynamicFeedResult.DynamicItem
    /// Returns whether the repost succeeded.
    let onRepost: (String) async -> Bool

    @State private var text = ""
    @State private var isPosting = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    // Presented as a sheet, which is its own presentation context: the tab
    // root's `accentContentBoundary()` lives inside a NavigationStack and
    // cannot reach here, so without this the screen renders the PLATFORM
    // accent while everything behind it renders the chosen one. Declared on
    // the view rather than at the call site so every presentation of it —
    // including future ones — is covered.
    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80, maxHeight: 140)

                    if text.isEmpty {
                        Text("Say something... (optional)")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }

                // Quoted original post.
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(item.modules?.moduleAuthor?.name ?? "")")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.biliAccent)
                    Text(quotedSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.control))

                if failed {
                    Label("Repost failed — try again", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(16)
            .appAmbientBrowseBackground()
            .navigationTitle("Repost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isPosting = true
                        failed = false
                        Task {
                            let ok = await onRepost(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            isPosting = false
                            if ok { dismiss() } else { failed = true }
                        }
                    } label: {
                        if isPosting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Repost").fontWeight(.semibold)
                        }
                    }
                    .disabled(isPosting)
                }
            }
        }
        .appAdaptiveSheet(compactDetents: [.height(320), .medium], padSizing: .form)
    }

    private var quotedSummary: String {
        let dynamic = item.modules?.moduleDynamic
        if let desc = dynamic?.desc?.text, !desc.isEmpty { return desc }
        let major = dynamic?.major
        return major?.archive?.title
            ?? major?.opus?.title
            ?? major?.opus?.summary?.text
            ?? major?.article?.title
            ?? major?.pgc?.title
            ?? major?.common?.title
            ?? "动态"
    }
}
