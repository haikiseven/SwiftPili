import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CommentEditingPickerReceipt: Equatable, Identifiable {
    let id = UUID()
    let mid: Int?
    let identityRevision: UInt64
}

struct CommentComposerBar: View {
    @Binding var text: String
    @Binding var pictures: [ComposedPicture]
    var placeholder = String(localized: "Write a comment...")
    var replyBanner: String?

    static func replyPlaceholder(to name: String) -> String {
        String(format: String(localized: "Reply to %@..."), name)
    }

    static func replyBannerText(for name: String) -> String {
        String(format: String(localized: "Replying to %@"), name)
    }
    var isSending = false
    var sendError: String?
    var focus: CommentComposerFocus?
    var autoFocusOnAppear = true
    var usesExternalMorphSurface = false
    var onCancelReply: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onSend: () -> Void
    var onCancelSend: (() -> Void)?
    var uploadScope: CommentComposerUploadScope?
    var isInteractionCurrent: () -> Bool = { true }

    @FocusState private var isFieldFocused: Bool
    @State private var focusAttemptID: UInt64 = 0
    @State private var lastHandledRequestToken: UInt64?
    @State private var lastHandledDismissToken: UInt64?
    @State private var isWindowAttached = false
    @State private var showEmotePicker = false
    @State private var showMentionPicker = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var legacyIsUploading = false
    @State private var legacyUploadError: String?
    @State private var errorAlertMessage: String?
    @State private var photoPickerOrigin: CommentComposerUploadOwner.Context?
    @State private var editingPickerOrigin: CommentComposerUploadOwner.Context?
    @State private var emotePickerAccount: CommentEditingPickerReceipt?
    @State private var mentionPickerAccount: CommentEditingPickerReceipt?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppMotion private var motion

    private var isUploading: Bool { uploadScope?.owner.isUploading ?? legacyIsUploading }

    private var uploadError: String? {
        if let scope = uploadScope { return scope.owner.error }
        return legacyUploadError
    }

    var body: some View {
        composerShell
            .sheet(isPresented: $showEmotePicker) { emotePicker }
            .sheet(isPresented: $showMentionPicker) { mentionPicker }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoSelection,
                maxSelectionCount: max(0, 9 - pictures.count),
                matching: .images
            )
            .onAppear { handleComposerAppear() }
            .onChange(of: isFieldFocused) {
                if isFieldFocused { PerfLog.firstTime("comment field focus") }
            }
            .onChange(of: focus?.requestToken) { _, token in handleFocusRequestTokenChange(token) }
            .onChange(of: focus?.dismissToken) { _, token in handleFocusDismissTokenChange(token) }
            .task(id: focusAttemptID) { await acquireLocalFocusWithRetries() }
            .onChange(of: showPhotoPicker) { if showPhotoPicker { PerfLog.firstTime("photo picker open") } }
            .onChange(of: showEmotePicker) { if showEmotePicker { PerfLog.firstTime("emote picker open") } }
            .onChange(of: photoSelection) { handlePhotoSelectionChange() }
            .onChange(of: uploadScope?.context) { _, _ in handleUploadContextChange() }
            .onChange(of: sendError) { _, message in
                guard let message, isInteractionCurrent() else { return }
                errorAlertMessage = message
            }
            .onChange(of: uploadError) { _, message in
                guard let message, isInteractionCurrent() else { return }
                errorAlertMessage = message
            }
            .alert(
                "Operation Failed",
                isPresented: Binding(
                    get: { errorAlertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorAlertMessage = nil
                            legacyUploadError = nil
                        }
                    }
                ),
                presenting: errorAlertMessage
            ) { _ in
                Button("OK", role: .cancel) {
                    errorAlertMessage = nil
                    legacyUploadError = nil
                }
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var composerShell: some View {
        if usesExternalMorphSurface {
            composerContentStack
        } else {
            composerContentStack
                .composerSurface(reduceTransparency: reduceTransparency)
                .padding(.horizontal, AppSpacing.l)
                .padding(.bottom, IPadKeyboardComposerLayout.keyboardBottomSpacing)
        }
    }

    private var composerContentStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let replyBanner { replyHeader(replyBanner) }
            if !pictures.isEmpty || isUploading { attachmentsRow }
            editorField
            toolsRow
        }
    }

    private func handlePhotoSelectionChange() {
        let items = photoSelection
        guard !items.isEmpty else { return }
        photoSelection = []
        guard isInteractionCurrent() else { return }
        if let scope = uploadScope {
            guard let origin = photoPickerOrigin, let batch = scope.prepare(origin: origin) else { return }
            let task = Task { await upload(items, scope: scope, batch: batch) }
            scope.owner.attach(task, to: batch)
        } else {
            Task { await upload(items) }
        }
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pictures.enumerated()), id: \.element.imgSrc) { index, pic in
                    CoverImage(urlString: pic.imgSrc, displaySize: CGSize(width: 56, height: 56))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                guard isInteractionCurrent() else { return }
                                if let scope = uploadScope {
                                    guard scope.isCurrent(), pictures.indices.contains(index),
                                          pictures[index] == pic else { return }
                                }
                                pictures.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove image"))
                            .offset(x: 10, y: -10)
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                }

                if isUploading {
                    ProgressView()
                        .frame(width: 56, height: 56)
                        .background(AppFill.nested, in: RoundedRectangle(cornerRadius: AppRadius.thumbnail))
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.top, replyBanner == nil ? AppSpacing.m : AppSpacing.s)
            .padding(.bottom, AppSpacing.xs)
        }
    }

    private func toolButton(
        _ icon: String,
        accessibilityKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isInteractionCurrent(), uploadScope?.isCurrent() ?? true else { return }
            action()
        } label: {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text(accessibilityKey))
    }

    @MainActor
    private func upload(
        _ items: [PhotosPickerItem],
        scope: CommentComposerUploadScope,
        batch: CommentComposerUploadOwner.Batch
    ) async {
        defer { scope.owner.finish(batch) }
        for item in items {
            guard !Task.isCancelled, scope.admits(batch), pictures.count < 9 else { return }
            do {
                let prepared = try await prepareUpload(item) {
                    scope.admits(batch) && pictures.count < 9
                }
                guard !Task.isCancelled, scope.admits(batch), pictures.count < 9 else { return }
                let result = try await UploadAPI.uploadImage(prepared.data)
                guard !Task.isCancelled, scope.admits(batch), pictures.count < 9 else { return }
                pictures.append(ComposedPicture(
                    imgSrc: result.imageUrl,
                    width: result.imageWidth ?? prepared.width,
                    height: result.imageHeight ?? prepared.height
                ))
            } catch {
                let failure = error as NSError
                guard !Task.isCancelled, scope.admits(batch), !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true,
                      !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
                PlayerLog.log("[Composer] image upload failed: \(error)")
                scope.owner.setError(String(
                    format: String(localized: "Image upload failed: %@"),
                    error.localizedDescription
                ), for: batch)
            }
        }
    }

    @MainActor
    private func upload(_ items: [PhotosPickerItem]) async {
        legacyIsUploading = true
        legacyUploadError = nil
        defer { legacyIsUploading = false }
        for item in items {
            guard !Task.isCancelled, isInteractionCurrent(), pictures.count < 9 else { return }
            do {
                let prepared = try await prepareUpload(item) {
                    isInteractionCurrent() && pictures.count < 9
                }
                guard !Task.isCancelled, isInteractionCurrent(), pictures.count < 9 else { return }
                let result = try await UploadAPI.uploadImage(prepared.data)
                guard !Task.isCancelled, isInteractionCurrent(), pictures.count < 9 else { return }
                pictures.append(ComposedPicture(
                    imgSrc: result.imageUrl,
                    width: result.imageWidth ?? prepared.width,
                    height: result.imageHeight ?? prepared.height
                ))
            } catch {
                let failure = error as NSError
                guard !Task.isCancelled, isInteractionCurrent(), !(error is CancellationError),
                      (error as? BiliError)?.isCancellation != true,
                      !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
                PlayerLog.log("[Composer] image upload failed: \(error)")
                legacyUploadError = String(
                    format: String(localized: "Image upload failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }

    @MainActor
    private func prepareUpload(
        _ item: PhotosPickerItem, admitted: () -> Bool
    ) async throws -> CommentUploadImage.Prepared {
        try Task.checkCancellation()
        guard admitted() else { throw CancellationError() }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CommentUploadImage.PreparationError.unreadable
        }
        try Task.checkCancellation()
        guard admitted() else { throw CancellationError() }
        let prepared = try await CommentUploadImage.prepare(data)
        try Task.checkCancellation()
        guard admitted() else { throw CancellationError() }
        return prepared
    }
}

private enum CommentUploadImage {
    struct Prepared: Sendable {
        let data: Data
        let width: Double
        let height: Double
    }

    enum PreparationError: LocalizedError {
        case unreadable

        var errorDescription: String? { String(localized: "Could not read the selected image") }
    }

    private static let maximumPixelDimension = 4096

    nonisolated static func prepare(_ data: Data) async throws -> Prepared {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool { try encode(data) }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let prepared = try await task.value
            try Task.checkCancellation()
            return prepared
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func encode(_ data: Data) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           width.doubleValue.isFinite, height.doubleValue.isFinite,
           width.doubleValue > 0, height.doubleValue > 0 else { throw PreparationError.unreadable }
        let dimension = min(Double(maximumPixelDimension), max(width.doubleValue, height.doubleValue))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(dimension))
        ]
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreparationError.unreadable
        }
        try Task.checkCancellation()
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw PreparationError.unreadable
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.unreadable }
        try Task.checkCancellation()
        return Prepared(data: encoded as Data, width: Double(image.width), height: Double(image.height))
    }
}

private extension CommentComposerBar {
    func captureEditingPickerAccount() -> CommentEditingPickerReceipt {
        let mid = AuthManager.shared.dedeUserID.flatMap(Int.init)
        return CommentEditingPickerReceipt(
            mid: mid.flatMap { $0 > 0 ? $0 : nil },
            identityRevision: AccountManager.shared.identityRevision
        )
    }

    @ViewBuilder var emotePicker: some View {
        if let emotePickerAccount {
            EmotePickerSheet(
                account: emotePickerAccount,
                isCurrent: { editingPickerIsCurrent },
                onPick: { token in
                    guard editingPickerIsCurrent else { return }
                    interactionText.wrappedValue += token
                }
            )
            .id(emotePickerAccount.id)
            .appAdaptiveSheet(compactDetents: [.height(340), .medium], padSizing: .form)
        }
    }

    @ViewBuilder var mentionPicker: some View {
        if let mentionPickerAccount {
            MentionPickerSheet(
                account: mentionPickerAccount,
                isCurrent: { editingPickerIsCurrent },
                onPick: { name in
                    guard editingPickerIsCurrent else { return }
                    interactionText.wrappedValue += "@\(name) "
                }
            )
            .id(mentionPickerAccount.id)
            .appAdaptiveSheet(compactDetents: [.medium, .large], padSizing: .form)
        }
    }

    func replyHeader(_ banner: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.s) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.biliAccent)
                    .accessibilityHidden(true)

                Text(banner)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .appValueFeedback(value: banner)

                Spacer(minLength: AppSpacing.s)

                Button {
                    guard isInteractionCurrent() else { return }
                    onCancelReply?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
                .accessibilityLabel(Text("Cancel reply"))
            }
            .padding(.leading, AppSpacing.l)
            .padding(.trailing, AppSpacing.xs)

            Divider()
                .opacity(0.18)
                .padding(.horizontal, AppSpacing.l)
        }
    }

    var editorField: some View {
        TextField(placeholder, text: interactionText, axis: .vertical)
            .font(.body)
            .lineLimit(2 ... 6)
            .focused($isFieldFocused)
            .disabled(!isInteractionCurrent())
            .padding(.horizontal, AppSpacing.l)
            .padding(.top, (replyBanner == nil && pictures.isEmpty && !isUploading) ? 14 : AppSpacing.s)
            .padding(.bottom, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ComposerWindowAttachmentProbe(
                    onAttach: handleWindowAttach,
                    onDetach: handleWindowDetach
                )
                .frame(width: 0, height: 0)
            }
    }

    var toolsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppSpacing.xs) {
                HStack(spacing: 2) {
                    leadingToolButtons
                }
                Spacer(minLength: AppSpacing.s)
                collapseButton
                sendControl
            }
            VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    HStack(spacing: 2) {
                        leadingToolButtons
                    }
                    Spacer(minLength: AppSpacing.s)
                    collapseButton
                }
                sendControl
            }
        }
        .padding(.leading, AppSpacing.xs)
        .padding(.trailing, AppSpacing.xs)
        .padding(.top, 2)
        .padding(.bottom, AppSpacing.xs)
    }

    @ViewBuilder
    var leadingToolButtons: some View {
        toolButton("face.smiling", accessibilityKey: "Stickers") {
            editingPickerOrigin = uploadScope?.context
            emotePickerAccount = captureEditingPickerAccount()
            showEmotePicker = true
        }
        .disabled(!isInteractionCurrent())

        toolButton("at", accessibilityKey: "Mention user") {
            editingPickerOrigin = uploadScope?.context
            mentionPickerAccount = captureEditingPickerAccount()
            showMentionPicker = true
        }
        .disabled(!isInteractionCurrent())

        toolButton("photo", accessibilityKey: "Add image") {
            photoPickerOrigin = uploadScope?.context
            showPhotoPicker = true
        }
        .disabled(!isInteractionCurrent() || pictures.count >= 9 || (uploadScope != nil && isUploading))
    }

    var collapseButton: some View {
        Button {
            guard isInteractionCurrent(), uploadScope?.isCurrent() ?? true else { return }
            focusAttemptID = 0
            if let focus {
                focus.dismiss()
            } else {
                isFieldFocused = false
            }
            onCollapse?()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(
            onCollapse != nil
                ? Text("Collapse editor and keep draft")
                : Text("Dismiss keyboard")
        )
    }

    var sendControl: some View {
        let microDuration = AppMotionPolicy.duration(for: .microControl, reduceMotion: false)
        return ZStack {
            if isSending {
                if let onCancelSend {
                    cancelSendButton(onCancelSend)
                } else {
                    sendingBadge
                }
            } else {
                sendActionButton
            }
        }
        .animation(motion.feedbackAnimation(normal: .easeInOut(duration: microDuration)), value: isSending)
        .animation(motion.feedbackAnimation(normal: .easeInOut(duration: microDuration)), value: canSend)
    }

    func cancelSendButton(_ cancel: @escaping () -> Void) -> some View {
        Button {
            guard isInteractionCurrent() else { return }
            cancel()
        } label: {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Cancel")
                    .font(.caption.weight(.semibold))
                    .fixedSize()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, AppSpacing.m)
            .frame(height: 32)
            .background(AppFill.inset, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.appControl)
        .accessibilityLabel(Text("Cancel sending"))
        .accessibilityValue(Text("Sending…"))
        .transition(.opacity)
    }

    var sendingBadge: some View {
        FloatingComposerSendButton(
            canSend: false,
            isBusy: true,
            isSendingWithoutCancel: true,
            onSend: {}
        )
        .transition(.opacity)
    }

    var sendActionButton: some View {
        FloatingComposerSendButton(
            canSend: canSend,
            isBusy: isUploading,
            onSend: {
                guard isInteractionCurrent(), canSend else { return }
                onSend()
            }
        )
        .transition(.opacity)
    }

    var editingPickerIsCurrent: Bool {
        guard isInteractionCurrent() else { return false }
        guard let scope = uploadScope else { return true }
        return editingPickerOrigin == scope.context && scope.isCurrent()
    }

    var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isInteractionCurrent() && (hasText || !pictures.isEmpty) && !isSending && !isUploading
    }

    var interactionText: Binding<String> {
        Binding(get: { text }, set: { value in
            guard isInteractionCurrent() else { return }
            text = value
        })
    }

    private var canAcquireFocus: Bool {
        isInteractionCurrent()
            && (uploadScope?.isCurrent() ?? true)
            && !isSending
            && !showEmotePicker
            && !showMentionPicker
            && !showPhotoPicker
    }

    private func handleComposerAppear() {
        PerfLog.firstTime("comment composer mount")
        lastHandledRequestToken = focus?.requestToken
        lastHandledDismissToken = focus?.dismissToken
        if autoFocusOnAppear {
            requestLocalFocus()
        }
    }

    private func handleUploadContextChange() {
        focusAttemptID = 0
        showEmotePicker = false
        showMentionPicker = false
        showPhotoPicker = false
        photoSelection = []
        legacyUploadError = nil
        errorAlertMessage = nil
        photoPickerOrigin = nil
        editingPickerOrigin = nil
        emotePickerAccount = nil
        mentionPickerAccount = nil
    }

    private func handleFocusRequestTokenChange(_ token: UInt64?) {
        guard let token, token != lastHandledRequestToken else { return }
        lastHandledRequestToken = token
        requestLocalFocus()
    }

    private func handleFocusDismissTokenChange(_ token: UInt64?) {
        guard let token, token != lastHandledDismissToken else { return }
        lastHandledDismissToken = token
        focusAttemptID = 0
        isFieldFocused = false
    }

    private func requestLocalFocus() {
        guard canAcquireFocus else { return }
        focusAttemptID &+= 1
        let attempt = focusAttemptID
        let dismissSnapshot = focus?.dismissToken
        let scope = uploadScope
        if isWindowAttached, !isFieldFocused { isFieldFocused = true }
        scheduleMainRunloopTurn {
            guard isFocusAttemptCurrent(attempt: attempt, dismissSnapshot: dismissSnapshot, scope: scope),
                  !isFieldFocused else { return }
            isFieldFocused = true
        }
    }

    private func handleWindowAttach(_ view: UIView) {
        focus?.attachHostView(view)
        isWindowAttached = true
        guard focusAttemptID > 0, canAcquireFocus, !isFieldFocused else { return }
        let attempt = focusAttemptID
        let dismissSnapshot = focus?.dismissToken
        let scope = uploadScope
        scheduleMainRunloopTurn {
            guard isFocusAttemptCurrent(attempt: attempt, dismissSnapshot: dismissSnapshot, scope: scope),
                  !isFieldFocused else { return }
            isFieldFocused = true
        }
    }

    private func handleWindowDetach(_ view: UIView) {
        focus?.detachHostView(view)
        scheduleMainRunloopTurn { isWindowAttached = false }
    }

    private func acquireLocalFocusWithRetries() async {
        let attempt = focusAttemptID
        guard attempt > 0 else { return }
        let dismissSnapshot = focus?.dismissToken
        let scope = uploadScope
        for delayMs in [24, 64, 120] {
            guard !isFieldFocused else { return }
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard isFocusAttemptCurrent(attempt: attempt, dismissSnapshot: dismissSnapshot, scope: scope) else {
                return
            }
            if !isFieldFocused { isFieldFocused = true }
        }
    }

    private func isFocusAttemptCurrent(
        attempt: UInt64, dismissSnapshot: UInt64?, scope: CommentComposerUploadScope?
    ) -> Bool {
        !Task.isCancelled
            && focusAttemptID == attempt
            && canAcquireFocus
            && (scope?.isCurrent() ?? true)
            && focus?.dismissToken == dismissSnapshot
    }
}

private extension View {
    func composerSurface(reduceTransparency: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
        return floatingGlassInputSurface(in: shape, interactive: true, reduceTransparency: reduceTransparency)
    }
}
