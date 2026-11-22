import SwiftUI

/// Drag-to-reorder ranking of the CDN provider families, consulted by
/// Smart CDN when nodes tie on ISP/region match. Probe latency alone
/// misjudges throughput — a Huawei edge often answers in a few ms yet
/// streams slowly — so the user's ranking decides before latency does.
/// Reordering re-sorts the existing sweep results immediately; no
/// re-probe is needed.
struct CDNProviderPriorityView: View {
    @State private var order = CDNProvider.priority

    var body: some View {
        List {
            Section {
                ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                    HStack(spacing: 12) {
                        Text(verbatim: "\(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(index == 0 ? Color.biliAccent : Color.secondary)
                            .frame(width: 20)
                        CDNProviderMark(provider: provider)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.title)
                                .font(.subheadline)
                            Text("\(provider.services.count) nodes")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove(perform: move)
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth()
        .navigationTitle(Text("Provider Priority", comment: "CDN provider priority nav title"))
        .navigationBarTitleDisplayMode(.inline)
        // Always-on edit mode: permanent drag handles, no Edit button
        // dance. No onDelete is attached, so rows only move.
        .environment(\.editMode, .constant(.active))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    order = CDNProvider.defaultPriority
                    persist()
                } label: {
                    Text("Reset", comment: "Reset provider priority to default")
                }
                // Interactive text follows the global accent (the app
                // sets no root-level tint, so this would default to
                // system blue). Disabled state still grays out.
                .tint(Color.biliAccent)
                .disabled(order == CDNProvider.defaultPriority)
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        CDNProvider.priority = order
        SmartCDNSelector.shared.providerPriorityChanged()
    }
}
