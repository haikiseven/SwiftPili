import Kingfisher
import SwiftUI

// MARK: - Emote Picker

struct EmotePickerSheet: View {
    struct PanelRequest: Equatable {
        let id = UUID()
        let account: CommentEditingPickerReceipt
    }

    let account: CommentEditingPickerReceipt
    let isCurrent: () -> Bool
    let onPick: (String) -> Void

    @State private var packages: [EmotePanelResult.EmotePackage] = []
    @State private var selectedPackage: Int = 0
    @State private var hasAttempted = false
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var recoveryRequest: PanelRequest?
    @State private var activeRequest: PanelRequest?
    @State private var requestTask: Task<Void, Never>?
    @State private var isRetired = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        VStack(spacing: 0) {
            if !lifetimeIsCurrent {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Unavailable", systemImage: "face.smiling",
                        description: Text("Close and reopen stickers to continue.")
                    )
                    closeButton
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 16)
            } else if !hasLoaded || packages.isEmpty {
                Spacer()
                loadingFeedback
                Spacer()
            } else {
                packageStrip
                Divider().opacity(0.35)
                ScrollView {
                    if packages.indices.contains(selectedPackage) {
                        packageGrid(packages[selectedPackage])
                    }
                }
            }
        }
        .onAppear {
            if !hasAttempted { startLoad() }
        }
        .onChange(of: lifetimeIsCurrent) { _, current in
            if !current { retire() }
        }
        .onDisappear { retire() }
    }
}

private extension EmotePickerSheet {
    var isLoading: Bool { activeRequest != nil }

    var lifetimeIsCurrent: Bool {
        let revision = AccountManager.shared.identityRevision
        let mid = AuthManager.shared.dedeUserID.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        return !isRetired && account.identityRevision == revision && account.mid == mid && isCurrent()
    }

    var packageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                    let isSelected = selectedPackage == index
                    Button {
                        guard validateLifetime(), packages.indices.contains(index) else { return }
                        selectedPackage = index
                    } label: {
                        HStack(spacing: 6) {
                            if !package.isTextPackage, let icon = package.url, !icon.isEmpty {
                                emoteThumbnail(icon, size: 18, showsCover: false)
                            }
                            Text(package.text ?? "\(package.id)")
                                .font(.subheadline)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(
                            isSelected
                                ? AnyShapeStyle(Color.biliAccent.opacity(0.14))
                                : AnyShapeStyle(AppFill.nested),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? AnyShapeStyle(.biliAccent) : AnyShapeStyle(.primary))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.appControl)
                }
            }
            .padding(.horizontal, AppSpacing.l)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    func packageGrid(_ package: EmotePanelResult.EmotePackage) -> some View {
        if package.isTextPackage {
            kaomojiGrid(package)
        } else if package.usesLargeStickerGrid {
            largeStickerGrid(package)
        } else {
            smallEmoteGrid(package)
        }
    }

    func kaomojiGrid(_ package: EmotePanelResult.EmotePackage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(package.emote ?? []) { emote in
                Button {
                    guard validateLifetime() else { return }
                    onPick(emote.text)
                } label: {
                    Text(emote.text)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            AppFill.nested,
                            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
    }

    func largeStickerGrid(_ package: EmotePanelResult.EmotePackage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 12)], spacing: 14) {
            ForEach(package.emote ?? []) { emote in
                Button {
                    guard validateLifetime() else { return }
                    onPick(emote.text)
                } label: {
                    VStack(spacing: 4) {
                        if emote.url.isEmpty || emote.type == 4 {
                            Text(emote.text)
                                .font(.caption2)
                                .minimumScaleFactor(0.4)
                                .lineLimit(2)
                                .frame(width: 54, height: 54)
                        } else {
                            emoteThumbnail(emote.url, size: 54)
                        }
                        if let alias = emote.meta?.alias?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !alias.isEmpty {
                            Text(alias)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(
                        AppFill.nested,
                        in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
                .buttonStyle(.appControl)
                .accessibilityLabel(Text(emote.meta?.alias ?? emote.text))
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
    }

    func smallEmoteGrid(_ package: EmotePanelResult.EmotePackage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 10)], spacing: 12) {
            ForEach(package.emote ?? []) { emote in
                Button {
                    guard validateLifetime() else { return }
                    onPick(emote.text)
                } label: {
                    Group {
                        if emote.url.isEmpty || emote.type == 4 {
                            Text(emote.text)
                                .font(.caption2)
                                .minimumScaleFactor(0.4)
                                .lineLimit(1)
                        } else {
                            emoteThumbnail(emote.url, size: 34)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appControl)
                .accessibilityLabel(Text(emote.meta?.alias ?? emote.text))
            }
        }
        .padding(.horizontal, AppSpacing.l)
        .padding(.vertical, AppSpacing.m)
    }

    @ViewBuilder
    func emoteThumbnail(_ urlString: String, size: CGFloat, showsCover: Bool = true) -> some View {
        let kfImage = KFImage(URL(string: urlString.httpsURL.biliResized(
            toPixel: CGSize(width: size * displayScale, height: size * displayScale)
        )))
        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: size, height: size)))
        .backgroundDecode()
        .scaleFactor(displayScale)
        .cancelOnDisappear(true)
        .resizable()

        if showsCover {
            kfImage
                .imageLoadingCover(shape: .roundedRect(AppRadius.thumbnail), shorterSide: size)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            kfImage
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder var loadingFeedback: some View {
        if isLoading || !hasAttempted {
            ProgressView()
        } else if let recoveryRequest {
            VStack(spacing: 8) {
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Retry") { startLoad(retrying: recoveryRequest) }
            }
            .padding(.horizontal, 16)
        } else if hasLoaded {
            VStack(spacing: 12) {
                Text("No stickers available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                closeButton
            }
        }
    }

    var closeButton: some View {
        Button("Close") {
            retire()
            dismiss()
        }
    }

    func validateLifetime() -> Bool {
        guard lifetimeIsCurrent else {
            retire()
            return false
        }
        return true
    }

    func retire() {
        isRetired = true
        requestTask?.cancel()
        requestTask = nil
        activeRequest = nil
        recoveryRequest = nil
        loadError = nil
    }

    func startLoad(retrying recovery: PanelRequest? = nil) {
        guard !Task.isCancelled, validateLifetime(), activeRequest == nil, !hasLoaded else { return }
        if let recovery {
            guard recoveryRequest == recovery, recovery.account == account else { return }
        } else {
            guard !hasAttempted, recoveryRequest == nil else { return }
        }
        let request = PanelRequest(account: account)
        hasAttempted = true
        loadError = nil
        recoveryRequest = nil
        activeRequest = request
        requestTask = Task { await load(request) }
    }

    func requestIsCurrent(_ request: PanelRequest) -> Bool {
        activeRequest == request && request.account == account && validateLifetime()
    }

    func load(_ request: PanelRequest) async {
        defer {
            if activeRequest == request {
                activeRequest = nil
                requestTask = nil
            }
        }
        guard requestIsCurrent(request) else { return }
        guard !Task.isCancelled else {
            recoveryRequest = request
            return
        }
        do {
            let panel = try await CommentAPI.getEmotePanel()
            guard requestIsCurrent(request) else { return }
            guard !Task.isCancelled else {
                recoveryRequest = request
                return
            }
            guard let receivedPackages = panel.packages else {
                loadError = String(localized: "Could not load stickers")
                recoveryRequest = request
                return
            }
            packages = receivedPackages.filter { !($0.emote ?? []).isEmpty }
            selectedPackage = 0
            hasLoaded = true
        } catch {
            guard requestIsCurrent(request) else { return }
            recoveryRequest = request
            guard !Task.isCancelled, !error.isCancellation else { return }
            loadError = error.localizedDescription
        }
    }
}
