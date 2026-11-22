import PhotosUI
import SwiftUI

/// `CaseIterable` so the iPad sidebar's **My Content** rows can be checked
/// against this list rather than against a second copy of it — see
/// `SidebarDestination` and `NavigationProjectionTests`.
enum MineQuickAccessItem: String, Hashable, CaseIterable {
    case favorites
    case history
    case watchLater
    case downloads

    var icon: String {
        switch self {
        case .favorites: "star.fill"
        case .history: "clock.arrow.circlepath"
        case .watchLater: "clock.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .favorites: "Favorites"
        case .history: "History"
        case .watchLater: "Watch Later"
        case .downloads: "Downloads"
        }
    }

    var route: Route {
        switch self {
        case .favorites: .favorites
        case .history: .history
        case .watchLater: .watchLater
        case .downloads: .downloads
        }
    }
}

enum MineQuickAccessPolicy {
    static func items(isLoggedIn: Bool) -> [MineQuickAccessItem] {
        if isLoggedIn {
            return [.favorites, .history, .watchLater, .downloads]
        }
        return [.downloads]
    }
}

struct MineView: View {
    @State private var viewModel: MineViewModel
    @State private var showEditProfile = false
    private let loggedInOverride: Bool?
    private var isLoggedIn: Bool { loggedInOverride ?? authManager.isLoggedIn }
    private var authManager: AuthManager { AuthManager.shared }
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(viewModel: MineViewModel? = nil, loggedInOverride: Bool? = nil) {
        self.loggedInOverride = loggedInOverride
        _viewModel = State(initialValue: viewModel ?? MineViewModel())
    }

    var body: some View {
        List {
            Group {
                MineProfileSection(viewModel: viewModel, isLoggedIn: isLoggedIn)

                if !sidebarCarriesTheseRows {
                    MineQuickAccessSection(isLoggedIn: isLoggedIn)
                }

                if isLoggedIn {
                    MineHistorySection(viewModel: viewModel)
                    settingsSection
                    logoutSection
                } else {
                    settingsSection
                }
            }
            .listRowBackground(AppFill.card)
        }
        .refreshable {
            await viewModel.load()
            await viewModel.loadHistory()
        }
        .readableFormWidth(.ambientBrowse)
        .scrollsToTopOnTabReselect(.mine)
        .navigationTitle("Mine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isLoggedIn, viewModel.userInfo != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEditProfile = true }.accessibilityLabel(Text("Edit Profile"))
                }
            }
        }
        .task {
            await viewModel.load()
            await viewModel.loadHistory()
        }
        .sheet(isPresented: $showEditProfile) {
            MineEditProfileContent(viewModel: viewModel)
        }
        // Raised by the post-switch nav probe; presented here because the
        // switcher has usually dismissed by the time the probe answers
        // (and this whole tab tree was just rebuilt by the switch).
        .alert(
            "Session expired",
            isPresented: Binding(
                get: { AccountManager.shared.expiredSessionAlert != nil },
                set: { if !$0 { AccountManager.shared.expiredSessionAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "%@'s login is no longer valid. Log in again via Add Account."),
                AccountManager.shared.expiredSessionAlert ?? ""
            ))
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            // Visible logged-out too while other accounts remain saved —
            // that is the re-activation path after a logout.
            if isLoggedIn || !AccountManager.shared.accounts.isEmpty {
                NavigationLink {
                    AccountSwitcherView()
                } label: {
                    Label {
                        Text("Accounts")
                    } icon: {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink {
                SettingsView()
            } label: {
                Label {
                    Text("Settings")
                } icon: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(AppFill.card)
    }

    // MARK: - Logout

    private var logoutSection: some View {
        Section {
            Button("Logout", role: .destructive) {
                authManager.logout()
                viewModel.userInfo = nil
                viewModel.history = []
            }
        }
        .listRowBackground(AppFill.card)
    }

    /// Whole coins render bare ("2345"), halves keep one decimal.
    static func coinText(_ coins: Double) -> String {
        coins.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", coins)
            : String(format: "%.1f", coins)
    }
}

/// The sheet owns its profile read even when SwiftUI evaluates its content.
struct MineEditProfileContent: View {
    let viewModel: MineViewModel

    var body: some View {
        if let user = viewModel.userInfo {
            EditProfileSheet(user: user) {
                await viewModel.load()
            }
        }
    }
}

// MARK: - Edit Profile (username / avatar)

/// In-app profile editing. Renaming costs 6 coins (BiliBili's fee) —
/// the confirmation spells that out and the server's coded refusal
/// (e.g. insufficient balance) is surfaced verbatim. Avatars are
/// REVIEWED by BiliBili asynchronously: the picked image is echoed
/// locally right away, but the served URL keeps answering the old
/// face until review passes — profile refreshes pick it up later.
private struct EditProfileSheet: View {
    let user: UserInfo
    var onUpdated: () async -> Void

    @State private var name: String
    @State private var sign: String
    @State private var photoSelection: PhotosPickerItem?
    @State private var localAvatar: UIImage?
    @State private var isUploadingAvatar = false
    @State private var isSavingName = false
    @State private var isSavingSign = false
    @State private var showRenameConfirm = false
    @State private var notice: String?
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(user: UserInfo, onUpdated: @escaping () async -> Void) {
        self.user = user
        self.onUpdated = onUpdated
        _name = State(initialValue: user.name)
        _sign = State(initialValue: user.sign ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            Form {
                Section {
                    HStack(spacing: 14) {
                        Group {
                            if let localAvatar {
                                Image(uiImage: localAvatar)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                AvatarImage(urlString: user.face, size: 64)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())

                        // State branch OUTSIDE the picker: its label
                        // closure is @Sendable in the current SDK and
                        // cannot touch main-actor view state.
                        if isUploadingAvatar {
                            ProgressView()
                        } else {
                            let accent = Color.biliAccent
                            PhotosPicker(selection: $photoSelection, matching: .images) {
                                Text("Change Avatar")
                                    .font(.subheadline)
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Avatar")
                }

                Section {
                    TextField(String(localized: "Username"), text: $name)
                    Button {
                        showRenameConfirm = true
                    } label: {
                        if isSavingName {
                            ProgressView()
                        } else {
                            Text("Save")
                                .foregroundStyle(Color.biliAccent)
                        }
                    }
                    .disabled(isSavingName || trimmedName.isEmpty || trimmedName == user.name)
                } header: {
                    Text("Username")
                }

                Section {
                    TextField(String(localized: "Bio"), text: $sign, axis: .vertical)
                        .lineLimit(2 ... 5)
                    Button {
                        Task { await saveSign() }
                    } label: {
                        if isSavingSign {
                            ProgressView()
                        } else {
                            Text("Save")
                                .foregroundStyle(Color.biliAccent)
                        }
                    }
                    .disabled(isSavingSign || sign == (user.sign ?? ""))
                } header: {
                    Text("Bio")
                }

                if let notice {
                    Section {
                        Label {
                            Text(verbatim: notice)
                                .font(.caption)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                if let errorText {
                    Section {
                        Text(verbatim: errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listRowBackground(AppFill.card)
            .readableFormWidth(.ambientBrowse)
            .navigationTitle(Text("Edit Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Renaming costs 6 coins. Continue?",
                isPresented: $showRenameConfirm,
                titleVisibility: .visible
            ) {
                Button("Rename (6 coins)") {
                    Task { await saveName() }
                }
            }
            .onChange(of: photoSelection) {
                guard let item = photoSelection else { return }
                photoSelection = nil
                Task { await uploadAvatar(item) }
            }
        }
    }

    private func saveName() async {
        isSavingName = true
        errorText = nil
        notice = nil
        defer { isSavingName = false }
        do {
            _ = try await UserAPI.updateUsername(trimmedName)
            PlayerLog.log("[Profile] username updated → \(trimmedName) (6 coins deducted)")
            notice = String(localized: "Username updated — 6 coins deducted")
            await onUpdated()
        } catch {
            // The server refuses with a coded message (duplicate name,
            // insufficient coins, review) — show it verbatim.
            errorText = error.localizedDescription
            PlayerLog.log("[Profile] rename failed: \(error)")
        }
    }

    private func saveSign() async {
        isSavingSign = true
        errorText = nil
        notice = nil
        defer { isSavingSign = false }
        do {
            _ = try await UserAPI.updateSignature(sign.trimmingCharacters(in: .whitespacesAndNewlines))
            PlayerLog.log("[Profile] signature updated (\(sign.count) chars)")
            notice = String(localized: "Bio updated")
            await onUpdated()
        } catch {
            // Banned-word rejections etc. come back coded — show verbatim.
            errorText = error.localizedDescription
            PlayerLog.log("[Profile] signature update failed: \(error)")
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        errorText = nil
        notice = nil
        defer { isUploadingAvatar = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            errorText = String(localized: "Could not read the selected image")
            return
        }
        // Avatars are small — cap the upload at ~1024px JPEG.
        let capped = image.preparingThumbnail(of: CGSize(width: 1024, height: 1024)) ?? image
        let jpeg = capped.jpegData(compressionQuality: 0.9) ?? data
        do {
            try await UploadAPI.updateAvatar(jpeg)
            localAvatar = image
            notice = String(localized: "Avatar submitted — it may take a while to pass review")
            await onUpdated()
        } catch {
            errorText = error.localizedDescription
            PlayerLog.log("[Profile] avatar update failed: \(error)")
        }
    }
}

/// Whether this screen still has to draw its own shortcuts, out of the type
/// body and into an extension — SwiftLint caps that body at 300 lines and this
/// addition crossed it.
private extension MineView {
    /// The sidebar carries Favourites, History, Watch Later, Downloads and
    /// Following as rows of their own under **My Content**, so this screen
    /// drawing the same four shortcuts listed one set of destinations twice —
    /// once in the sidebar, and again inside the screen the sidebar's own
    /// account header opens.
    ///
    /// The condition is the SHELL's, not this screen's: a Max iPhone in
    /// landscape is `.regular` and has no sidebar, so dropping the shortcuts on
    /// the size class alone would leave them with no home at all.
    var sidebarCarriesTheseRows: Bool {
        ShellNavigationPolicy.showsSidebar(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            isRegularWidth: sizeClass == .regular
        )
    }
}
