import SwiftUI
import UIKit

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
                    UIPasteboard.general.string = entries
                        .map { entry in
                            "captured \(entry.capturedAt.formatted(date: .abbreviated, time: .standard))\n\(entry.text)"
                        }
                        .joined(separator: "\n\n----\n\n")
                    copied = true
                } label: {
                    Label {
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
