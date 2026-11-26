import SwiftUI

struct ComposeMomentView: View {
    let onPost: (String) async -> DynamicsViewModel.MomentPostOutcome
    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var charCount: Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var draftBinding: Binding<String> {
        Binding(get: { text }, set: { value in
            errorMessage = nil
            text = value
        })
    }

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: draftBinding)
                        .appFont(.messageBody)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)

                    if text.isEmpty {
                        Text("Share what's on your mind...")
                            .appFont(.messageBody)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Text("\(charCount)")
                        .appFont(.messageMeta)
                        .foregroundStyle(charCount > 0 ? .secondary : .tertiary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .appAmbientBrowseBackground()
            .navigationTitle("New Moment")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Operation Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { message in
                Text(message)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isPosting, charCount > 0 else { return }
                        isPosting = true
                        errorMessage = nil
                        Task {
                            let outcome = await onPost(text)
                            isPosting = false
                            switch outcome {
                            case .posted:
                                dismiss()
                            case .failed(let message):
                                errorMessage = message
                            case .cancelled:
                                break
                            }
                        }
                    } label: {
                        if isPosting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Post")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(charCount == 0 || isPosting)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .appAdaptiveSheet(compactDetents: [.large], padSizing: .form)
    }
}
