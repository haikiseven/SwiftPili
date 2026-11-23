import PhotosUI
import SwiftUI

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
    @Environment(\.authManager) private var authManager
    @Environment(\.accountManager) private var accountManager
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
            viewModel.bind(authManager: authManager, accountManager: accountManager)
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
            viewModel.bind(authManager: authManager, accountManager: accountManager)
            await viewModel.load()
            await viewModel.loadHistory()
        }
        .sheet(isPresented: $showEditProfile) {
            MineEditProfileContent(viewModel: viewModel)
        }
        .alert(
            "Session expired",
            isPresented: Binding(
                get: { accountManager.expiredSessionAlert != nil },
                set: { if !$0 { accountManager.expiredSessionAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "%@'s login is no longer valid. Log in again via Add Account."),
                accountManager.expiredSessionAlert ?? ""
            ))
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            if isLoggedIn || !accountManager.accounts.isEmpty {
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

    static func coinText(_ coins: Double) -> String {
        coins.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", coins)
            : String(format: "%.1f", coins)
    }
}

struct MineEditProfileContent: View {
    let viewModel: MineViewModel

    var body: some View {
        if let user = viewModel.userInfo {
            EditProfileSheet(user: user, viewModel: viewModel)
        }
    }
}

// MARK: - Edit Profile (username / avatar)

private struct EditProfileSheet: View {
    let user: UserInfo
    let viewModel: MineViewModel

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
    @Environment(\.accentStore) private var accentStore

    init(user: UserInfo, viewModel: MineViewModel) {
        self.user = user
        self.viewModel = viewModel
        _name = State(initialValue: user.name)
        _sign = State(initialValue: user.sign ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        accentedBody.tint(accentStore.contentTint)
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

                        if isUploadingAvatar {
                            ProgressView()
                        } else {
                            let accent = accentStore.semanticAccent
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
                                .foregroundStyle(accentStore.semanticAccent)
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
                                .foregroundStyle(accentStore.semanticAccent)
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
            try await viewModel.updateUsername(trimmedName)
            notice = String(localized: "Username updated — 6 coins deducted")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveSign() async {
        isSavingSign = true
        errorText = nil
        notice = nil
        defer { isSavingSign = false }
        do {
            try await viewModel.updateSignature(sign.trimmingCharacters(in: .whitespacesAndNewlines))
            notice = String(localized: "Bio updated")
        } catch {
            errorText = error.localizedDescription
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
        let capped = image.preparingThumbnail(of: CGSize(width: 1024, height: 1024)) ?? image
        let jpeg = capped.jpegData(compressionQuality: 0.9) ?? data
        do {
            try await viewModel.updateAvatar(jpegData: jpeg)
            localAvatar = image
            notice = String(localized: "Avatar submitted — it may take a while to pass review")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private extension MineView {
    var sidebarCarriesTheseRows: Bool {
        ShellNavigationPolicy.showsSidebar(
            isPad: DeviceCapability.supportsPadDetailSplit,
            isRegularWidth: sizeClass == .regular
        )
    }
}
