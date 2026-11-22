import SwiftUI
import UIKit

/// Plain-text view over `HangReportStore` — the in-app surface for MetricKit
/// hang, crash and exit reports in Settings → Experimental Features →
/// Diagnostic Tools, sibling of
/// PlaybackDebugReportView with the same transport: Copy All, no tethered
/// Mac. Reports are durable and capacity-bounded, so unlike the playback
/// ring there is no toggle and no capture window to miss — a freeze from
/// last session is still here.
struct HangReportView: View {
    @State private var entries: [HangReportStore.Entry] = []
    @State private var copied = false

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                Text("No hang, crash, or exit reports recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.capturedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.text)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(Text("App Reports"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // The delivery timestamp travels with the copy: the
                    // in-text "payload window" can span hours on next-launch
                    // delivery, so this is the datum that orders reports.
                    UIPasteboard.general.string = entries
                        .map { entry in
                            "captured \(entry.capturedAt.formatted(date: .abbreviated, time: .standard))\n\(entry.text)"
                        }
                        .joined(separator: "\n\n----\n\n")
                    copied = true
                } label: {
                    Label {
                        // Ternary INSIDE Text() would bypass localization —
                        // the String overload wins over LocalizedStringKey.
                        copied ? Text("Copied") : Text("Copy All")
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    entries = HangReportStore.shared.entries()
                    copied = false
                } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear {
            entries = HangReportStore.shared.entries()
        }
    }
}
