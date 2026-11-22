import SwiftUI

struct SponsorBlockPanel: View {
    let vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    private var manager: SponsorBlockManager { SponsorBlockManager.shared }

    @State private var markStart: Double?
    @State private var markEnd: Double?
    @State private var category: SponsorCategory = .sponsor
    @State private var actionType: SponsorActionType = .skip
    @State private var submitting = false
    @State private var voting: String?
    @State private var errorMessage: String?
    @State private var confirmSubmit = false

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            List {
                segmentsSection
                submitSection
            }
            .navigationTitle("SponsorBlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "SponsorBlock",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .appAdaptiveSheet(padSizing: .form)
    }

    // MARK: Segments

    private var segmentsSection: some View {
        Section {
            if manager.segments.isEmpty {
                Text(manager.isLoading ? "Loading…" : "No segments for this video yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.segments) { seg in
                    segmentRow(seg)
                }
            }
        } header: {
            Text("Segments")
        }
    }

    private func segmentRow(_ seg: SponsorSegment) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: AppRadius.badge)
                .fill(seg.category.color)
                .frame(width: 6, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(seg.category.displayName)
                    .font(.subheadline.weight(.medium))
                Text(seg.isPOI
                    ? FormatUtils.duration(Int(seg.start))
                    : "\(FormatUtils.duration(Int(seg.start))) – \(FormatUtils.duration(Int(seg.end)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await jump(to: seg.start) }
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .buttonStyle(.borderless)

            if voting == seg.uuid {
                ProgressView()
            } else {
                Button {
                    Task { await vote(seg, type: 1) }
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await vote(seg, type: 0) }
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Submit

    private var submitSection: some View {
        Section {
            HStack {
                Text("Start")
                Spacer()
                Text(markStart.map { FormatUtils.duration(Int($0)) } ?? "—")
                    .foregroundStyle(.secondary)
                Button("Set") { markStart = vm.displayTime }
                    .buttonStyle(.borderless)
            }
            HStack {
                Text("End")
                Spacer()
                Text(markEnd.map { FormatUtils.duration(Int($0)) } ?? "—")
                    .foregroundStyle(.secondary)
                Button("Set") { markEnd = vm.displayTime }
                    .buttonStyle(.borderless)
            }
            Picker("Category", selection: $category) {
                ForEach(SponsorCategory.submittable) { cat in
                    Text(cat.displayName).tag(cat)
                }
            }
            if category != .poiHighlight {
                Picker("Behavior", selection: $actionType) {
                    ForEach(SponsorActionType.submittable) { type in
                        Text(type.submitLabel).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }
            Button {
                confirmSubmit = true
            } label: {
                if submitting {
                    ProgressView()
                } else {
                    Text("Submit Segment")
                }
            }
            .disabled(submitting || !canSubmit)
            .confirmationDialog(
                "Submit this segment to the public SponsorBlock database?",
                isPresented: $confirmSubmit,
                titleVisibility: .visible
            ) {
                Button("Submit") { Task { await submit() } }
                Button("Cancel", role: .cancel) {}
            }
        } header: {
            Text("Submit a Segment")
        }
    }

    private var canSubmit: Bool {
        guard let s = markStart else { return false }
        if category == .poiHighlight { return true }
        guard let e = markEnd else { return false }
        return e > s
    }

    // MARK: Actions

    private func jump(to time: Double) async {
        vm.seek(to: time)
        dismiss()
    }

    private func vote(_ seg: SponsorSegment, type: Int) async {
        voting = seg.uuid
        defer { voting = nil }
        do {
            try await manager.vote(uuid: seg.uuid, type: type)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() async {
        guard let start = markStart else { return }
        let end = category == .poiHighlight ? start : (markEnd ?? start)
        submitting = true
        defer { submitting = false }
        do {
            try await manager.submit(
                start: start, end: end,
                category: category,
                actionType: category == .poiHighlight ? .poi : actionType,
                videoDuration: vm.duration
            )
            markStart = nil
            markEnd = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
