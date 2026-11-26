import SwiftUI
import UIKit

struct ManageFavoriteFoldersView: View {
    @State var folders: [FavoriteFolderResult.FavoriteFolder]
    @Environment(\.dismiss) private var dismiss

    @State private var showCreate = false
    @State private var newFolderName = ""
    @State private var pendingDelete: FavoriteFolderResult.FavoriteFolder?
    @State private var errorText: String?
    @State private var isWorking = false

    var body: some View {
        accentedBody.accentContentBoundary()
    }

    @ViewBuilder private var accentedBody: some View {
        NavigationStack {
            ManageFavoriteFoldersCollectionView(
                folders: folders,
                isDisabled: isWorking,
                onReorder: { reordered in
                    folders = reordered
                    let ids = reordered.map(\.id)
                    Task { await sort(ids: ids) }
                },
                onRequestDelete: { folder in
                    guard !folder.isDefault else { return }
                    pendingDelete = folder
                }
            )
            .readableFormWidth(.ambientBrowse)
            .navigationTitle("Manage Folders")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newFolderName = ""
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isWorking)
                }
            }
            .alert("New Folder", isPresented: $showCreate) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { create(isPrivate: false) }
                Button("Create Private") { create(isPrivate: true) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                String(format: String(localized: "Delete “%@”?"), pendingDelete?.title ?? ""),
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    if let folder = pendingDelete { delete(folder) }
                }
            } message: {
                Text("The folder and its saved list are removed from your account.")
            }
            .alert(
                "Operation Failed",
                isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func create(isPrivate: Bool) {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run {
            try await UserAPI.createFavoriteFolder(title: name, isPrivate: isPrivate)
        }
    }

    private func delete(_ folder: FavoriteFolderResult.FavoriteFolder) {
        guard !folder.isDefault else { return }
        run {
            try await UserAPI.deleteFavoriteFolder(mediaId: folder.id)
        }
    }

    private func sort(ids: [Int]) async {
        do {
            try await UserAPI.sortFavoriteFolders(orderedIds: ids)
        } catch {
            errorText = error.localizedDescription
            await resync()
        }
    }

    private func run(_ mutation: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await mutation()
            } catch {
                errorText = error.localizedDescription
            }
            await resync()
            isWorking = false
        }
    }

    private func resync() async {
        let mid = Int(AuthManager.shared.dedeUserID ?? "0") ?? 0
        if let result = try? await UserAPI.getFavorites(mid: mid) {
            folders = result.list ?? []
        }
    }
}

private struct ManageFavoriteFoldersCollectionView: View {
    let folders: [FavoriteFolderResult.FavoriteFolder]
    let isDisabled: Bool
    let onReorder: ([FavoriteFolderResult.FavoriteFolder]) -> Void
    let onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void

    var body: some View {
        let config = ManageFoldersConfig(
            folders: folders,
            isDisabled: isDisabled,
            onReorder: onReorder,
            onRequestDelete: onRequestDelete
        )
        UIKitCollectionHost(
            makeController: { ManageFavoriteFoldersController() },
            updateController: { controller in controller.update(config) }
        )
    }
}

@MainActor
private struct ManageFoldersConfig {
    let folders: [FavoriteFolderResult.FavoriteFolder]
    let isDisabled: Bool
    let onReorder: ([FavoriteFolderResult.FavoriteFolder]) -> Void
    let onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void
}

@MainActor
private final class ManageFavoriteFoldersController: UIKitBaseCollectionViewController {
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int>?
    private var folders: [FavoriteFolderResult.FavoriteFolder] = []
    private var folderByID: [Int: FavoriteFolderResult.FavoriteFolder] = [:]
    private var isDisabled = false
    private var onReorder: ([FavoriteFolderResult.FavoriteFolder]) -> Void = { _ in }
    private var onRequestDelete: (FavoriteFolderResult.FavoriteFolder) -> Void = { _ in }

    override var allowsSelectionHighlight: Bool { false }

    override func makeCollectionLayout() -> UICollectionViewLayout {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = .clear
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, !isDisabled,
                  let id = dataSource?.itemIdentifier(for: indexPath),
                  let folder = folderByID[id],
                  !folder.isDefault else {
                return nil
            }
            let action = UIContextualAction(
                style: .destructive,
                title: String(localized: "Delete Folder")
            ) { [weak self] _, _, completion in
                self?.onRequestDelete(folder)
                completion(true)
            }
            action.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [action])
        }
        return UICollectionViewCompositionalLayout.list(using: config)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.dragInteractionEnabled = true
        configureDataSource()
        applySnapshot()
    }

    override func shouldSelectItem(at indexPath: IndexPath) -> Bool { false }

    func update(_ config: ManageFoldersConfig) {
        onReorder = config.onReorder
        onRequestDelete = config.onRequestDelete
        isDisabled = config.isDisabled
        collectionView.isUserInteractionEnabled = !config.isDisabled

        let changed = config.folders.map { "\($0.id):\($0.title):\($0.mediaCount ?? -1):\($0.attr ?? -1)" }
            != folders.map { "\($0.id):\($0.title):\($0.mediaCount ?? -1):\($0.attr ?? -1)" }
        guard changed else { return }

        folders = config.folders
        folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        if isViewLoaded {
            applySnapshot()
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<
            ManageFolderListCell,
            FavoriteFolderResult.FavoriteFolder
        > { cell, _, folder in
            cell.configure(folder: folder)
        }

        let source = UICollectionViewDiffableDataSource<Int, Int>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            guard let self, let folder = folderByID[id] else { return nil }
            return collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: folder)
        }

        source.reorderingHandlers.canReorderItem = { [weak self] _ in
            !(self?.isDisabled ?? true)
        }
        source.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let orderedIDs = transaction.finalSnapshot.itemIdentifiers
            let reordered = orderedIDs.compactMap { folderByID[$0] }
            folders = reordered
            onReorder(reordered)
        }
        dataSource = source
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(folders.map(\.id), toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

@MainActor
private final class ManageFolderListCell: UICollectionViewListCell {
    private let folderIcon = UIKitFolderIconView(size: 24)
    private let titleLabel = UILabel()
    private let privateIconView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let defaultPill = UIView()
    private let defaultLabel = UILabel()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = UIColor(AppFill.card)
        backgroundConfiguration = background

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)

        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        privateIconView.tintColor = .secondaryLabel
        privateIconView.contentMode = .scaleAspectFit
        privateIconView.isHidden = true
        privateIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        privateIconView.setContentHuggingPriority(.required, for: .horizontal)

        defaultPill.backgroundColor = .tertiarySystemFill
        defaultPill.layer.cornerCurve = .continuous
        defaultPill.isHidden = true
        defaultLabel.translatesAutoresizingMaskIntoConstraints = false
        defaultLabel.text = String(localized: "Default")
        defaultLabel.textColor = .secondaryLabel
        defaultLabel.numberOfLines = 1
        defaultLabel.adjustsFontForContentSizeCategory = true
        defaultLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        defaultLabel.setContentHuggingPriority(.required, for: .horizontal)
        defaultPill.addSubview(defaultLabel)
        NSLayoutConstraint.activate([
            defaultLabel.topAnchor.constraint(equalTo: defaultPill.topAnchor, constant: 2),
            defaultLabel.bottomAnchor.constraint(equalTo: defaultPill.bottomAnchor, constant: -2),
            defaultLabel.leadingAnchor.constraint(equalTo: defaultPill.leadingAnchor, constant: 6),
            defaultLabel.trailingAnchor.constraint(equalTo: defaultPill.trailingAnchor, constant: -6),
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countLabel.numberOfLines = 1
        countLabel.textColor = .tertiaryLabel
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(folderIcon)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(privateIconView)
        stack.addArrangedSubview(defaultPill)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(countLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
        accessories = [.reorder(displayed: .always)]
    }

    func configure(folder: FavoriteFolderResult.FavoriteFolder) {
        let traits = traitCollection
        folderIcon.refreshAccent()
        titleLabel.text = folder.title
        titleLabel.font = UIKitFeedFont.systemFont(textStyle: .body, traitCollection: traits)

        privateIconView.isHidden = !folder.isPrivate
        if folder.isPrivate {
            privateIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                font: UIKitFeedFont.systemFont(textStyle: .caption2, weight: .semibold, traitCollection: traits)
            )
        }

        defaultPill.isHidden = !folder.isDefault
        if folder.isDefault {
            defaultLabel.font = UIKitFeedFont.systemFont(textStyle: .caption2, weight: .medium, traitCollection: traits)
            defaultPill.layer.cornerRadius = ceil(defaultLabel.font.lineHeight + 4) / 2
        }

        if let count = folder.mediaCount {
            countLabel.isHidden = false
            countLabel.text = "\(count)"
            countLabel.font = UIKitFeedFont.systemFont(
                textStyle: .caption,
                monospacedDigit: true,
                traitCollection: traits
            )
        } else {
            countLabel.isHidden = true
        }
    }
}
