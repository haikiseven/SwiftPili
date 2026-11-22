import Observation
import SwiftUI

/// Reduce-Transparency-aware Liquid Glass surface for immersive live room chrome.
private struct LiveImmersiveGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.floatingGlassInputSurface(
            in: shape,
            interactive: interactive,
            reduceTransparency: reduceTransparency
        )
    }
}

extension View {
    func liveImmersiveGlass<S: InsettableShape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(LiveImmersiveGlassModifier(shape: shape, interactive: interactive))
    }
}

/// Isolated live badge and 1 Hz network speed readout so periodic `player.stats`
/// updates never invalidate `LiveRoomView`'s root layout geometry.
struct LiveStatusSpeedBadge: View {
    let roomAvailability: LiveRoomAvailability
    let showNetworkSpeed: Bool
    let isPlayerOwner: Bool
    let player: PlayerViewModel
    var showsBackground: Bool = true

    @ViewBuilder
    var body: some View {
        let showsSpeed = showNetworkSpeed && isPlayerOwner && player.stats.networkSpeed > 0
        if roomAvailability == .live || showsSpeed {
            let content = HStack(spacing: 5) {
                if roomAvailability == .live {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                if showsSpeed {
                    Text(player.stats.networkSpeedText)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .accessibilityElement(children: .combine)

            if showsBackground {
                content
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liveImmersiveGlass(in: Capsule())
            } else {
                content
                    .padding(.trailing, 12)
            }
        }
    }
}

/// Owns the live danmaku draft text and in-flight send transaction outside
/// `LiveRoomView` so keystrokes do not re-evaluate the player or chat tree.
@MainActor
@Observable
final class LiveDanmakuDraftModel {
    var text = ""
    private(set) var isSending = false
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    func send(roomID: Int, viewModel: LiveRoomViewModel, dismissFocus: () -> Void) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !isSending else { return }
        isSending = true
        // Drop keyboard focus synchronously BEFORE the async round-trip so the
        // keyboard retracts immediately upon submission.
        dismissFocus()
        sendTask = Task {
            await viewModel.sendDanmaku(roomID: roomID, message: msg)
            isSending = false
            sendTask = nil
            // Cancelled mid-send: keep draft text for resend.
            guard !Task.isCancelled else { return }
            text = ""
        }
    }
}

/// Leaf danmaku composer supporting standard and immersive portrait surfaces.
struct LiveDanmakuInputBar: View {
    enum Style {
        case standard
        case immersive
        /// iPad landscape: independent Liquid Glass bar floating above the keyboard.
        case floating
    }

    let style: Style
    @Bindable var draft: LiveDanmakuDraftModel
    var isFocused: FocusState<Bool>.Binding
    let roomID: Int
    let viewModel: LiveRoomViewModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppMotion private var motion

    private var isImmersive: Bool { style == .immersive }

    private var canSend: Bool {
        !draft.isSending && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        inputPillContainer
            .padding(.horizontal, style == .floating ? 0 : AppSpacing.m)
            .padding(.vertical, AppSpacing.xs)
            .frame(minHeight: IPadKeyboardComposerLayout.pillHeight + AppSpacing.s)
    }

    private var inputPillContainer: some View {
        let pill = HStack(spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.s) {
                Image(systemName: "bubble.left")
                    .font(.callout)
                    .foregroundStyle(isImmersive ? AnyShapeStyle(.white.opacity(0.76)) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Group {
                    if isImmersive {
                        TextField(
                            "",
                            text: $draft.text,
                            prompt: Text("Say something...")
                                .foregroundStyle(.white.opacity(0.66))
                        )
                        .foregroundStyle(.white)
                    } else {
                        TextField("Say something...", text: $draft.text)
                    }
                }
                .font(.callout)
                .focused(isFocused)
                .onSubmit { triggerSend() }
                .accessibilityLabel(Text("Live chat message"))
            }
            .padding(.leading, IPadKeyboardComposerLayout.pillHorizontalPadding)
            .padding(.vertical, IPadKeyboardComposerLayout.pillVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)

            FloatingComposerSendButton(
                canSend: canSend,
                isBusy: draft.isSending,
                accessibilityLabel: "Send message",
                onSend: triggerSend,
                onCancel: { draft.cancelSend() }
            )
            .padding(.trailing, 1)
            .padding(.vertical, 1)
            .animation(motion.feedbackAnimation(normal: .easeInOut(duration: 0.2)), value: canSend)
            .animation(motion.feedbackAnimation(normal: .easeInOut(duration: 0.2)), value: draft.isSending)
        }
        .frame(minHeight: IPadKeyboardComposerLayout.pillHeight)

        return Group {
            if isImmersive {
                pill.liveImmersiveGlass(in: Capsule(), interactive: true)
            } else {
                // Same view structure for docked and floating so the text
                // field keeps keyboard focus when the surface changes.
                pill.background { fieldSurface }
            }
        }
    }

    @ViewBuilder
    private var fieldSurface: some View {
        if style == .floating {
            Color.clear.floatingGlassInputSurface(
                in: Capsule(),
                interactive: true,
                reduceTransparency: reduceTransparency
            )
        } else {
            Capsule().fill(AppFill.inset)
        }
    }

    private func triggerSend() {
        draft.send(roomID: roomID, viewModel: viewModel) {
            isFocused.wrappedValue = false
        }
    }
}
