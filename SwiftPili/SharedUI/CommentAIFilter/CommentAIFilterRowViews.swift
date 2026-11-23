import SwiftUI

struct CommentAIFilterRowContainer<Content: View>: View {
    let comment: CommentResult.CommentItem
    let upMid: Int?
    @ViewBuilder let content: (CommentAIAssessment?, @escaping () -> Void) -> Content

    @AppMotion private var motion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isExpanded = false
    @State private var showDetailSheet = false

    private let engine = CommentAIFilterEngine.shared

    var body: some View {
        let assessment = engine.assessment(for: comment, upMid: upMid)
        let isMatched = assessment?.matches(engine.config) == true
        let mode = engine.config.mode

        Group {
            if isMatched, mode == .autoCollapse, !isExpanded, let assessment {
                collapsedBar(assessment: assessment)
            } else {
                content(isMatched ? assessment : nil) {
                    showDetailSheet = true
                }
            }
        }
        .onAppear {
            engine.requestRefinementIfNeeded(for: comment, upMid: upMid)
        }
        .onDisappear {
            engine.cancelRefinement(for: comment.rpid)
        }
        .sheet(isPresented: $showDetailSheet) {
            if let assessment {
                let isRegularPad = DeviceCapability.supportsPadFormSheetPresentation
                    && horizontalSizeClass == .regular
                CommentAIFilterDetailSheet(
                    comment: comment,
                    assessment: assessment,
                    canRecollapse: mode == .autoCollapse && isExpanded,
                    isRegularWidth: isRegularPad,
                    onRecollapse: {
                        withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) {
                            isExpanded = false
                        }
                    },
                    onAllowAuthor: {
                        _ = engine.allowAuthor(mid: comment.mid, name: comment.member.uname)
                    }
                )
            }
        }
    }

    private func collapsedBar(assessment: CommentAIAssessment) -> some View {
        Button {
            withAnimation(motion.animation(normal: .easeInOut(duration: 0.2))) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Collapsed suspected AI comment · \(assessment.score)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                Spacer(minLength: AppSpacing.s)
                Text("Expand")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.biliAccent)
                    .fixedSize()
            }
            .padding(.horizontal, AppSpacing.m)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if dynamicTypeSize.isAccessibilitySize {
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(AppFill.inset)
                } else {
                    Capsule(style: .continuous)
                        .fill(AppFill.inset)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Expands the original comment"))
    }
}

struct CommentAIBadgeButton: View {
    let score: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.medium))
                    .imageScale(.small)
                    .foregroundStyle(Color.orange.opacity(0.75))
                Text("AI \(score)%")
                    .appFont(.overlayBadge)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.5)
                    )
            )
            .contentShape(Capsule().inset(by: -10))
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("Suspected AI \(score)%"))
        .accessibilityHint(Text("Shows matched reasons and author whitelist option"))
    }
}

private struct CommentAIFilterDetailSheet: View {
    let comment: CommentResult.CommentItem
    let assessment: CommentAIAssessment
    let canRecollapse: Bool
    let isRegularWidth: Bool
    let onRecollapse: () -> Void
    let onAllowAuthor: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Detection Result") {
                    LabeledContent("Suspicion Score") {
                        Text("\(assessment.score)%")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.orange.opacity(0.85))
                    }
                    LabeledContent("Detection Stage") {
                        Text(stageLabel)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Author", value: comment.member.uname)
                    LabeledContent("MID") {
                        Text(verbatim: String(comment.mid))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Matched Signals") {
                    if assessment.reasons.isEmpty {
                        Text("Combined account and text heuristics exceeded threshold.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(assessment.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "sparkle")
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    Button {
                        onAllowAuthor()
                        dismiss()
                    } label: {
                        Label("Add @\(comment.member.uname) to Whitelist", systemImage: "checkmark.shield")
                    }

                    if canRecollapse {
                        Button {
                            onRecollapse()
                            dismiss()
                        } label: {
                            Label("Collapse Comment Again", systemImage: "rectangle.compress.vertical")
                        }
                    }
                } footer: {
                    Text("Whitelisted authors are stored locally and never filtered on this device.")
                }

                if let access = ExperimentalSettingsStore.shared.captureAccess(.aiCommentFilter) {
                    Section {
                        NavigationLink {
                            CommentAIFilterRulesView(access: access)
                        } label: {
                            Label("Detection Rules", systemImage: "checklist")
                        }
                    }
                }
            }
            .listRowBackground(AppFill.card)
            .navigationTitle("AI Comment Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accentContentBoundary()
        .modifier(CommentAIFilterSheetPresentation(isRegularWidth: isRegularWidth))
    }

    private var stageLabel: String {
        switch assessment.stage {
        case .heuristic:
            String(localized: "Local Heuristic Rules")
        case .refined:
            String(localized: "Local Rules + Apple Intelligence")
        }
    }
}

private struct CommentAIFilterSheetPresentation: ViewModifier {
    let isRegularWidth: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRegularWidth {
            if #available(iOS 18.0, *) {
                content.presentationSizing(.form)
            } else {
                content
            }
        } else {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
