import Observation
import SwiftUI

/// Group membership editor for one followed UP: multi-select across
/// Special Follow (-10), Default (0) and custom groups, preloaded with
/// the user's current set (x/relation/tag/user), saved as a REPLACE
/// (x/relation/tags/addUsers). A new group can be created inline.
struct FollowGroupSheet: View {
    let user: FollowingListView.FollowingItem
    /// Fired after a successful save so the list refreshes counts.
    var onSaved: () -> Void

    @State private var editor: FollowGroupEditor
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @Environment(\.dismiss) private var dismiss

    init(user: FollowingListView.FollowingItem, tags: [RelationTag], onSaved: @escaping () -> Void) {
        self.user = user
        self.onSaved = onSaved
        _editor = State(initialValue: FollowGroupEditor(mid: user.mid, tags: tags))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(editor.allTags) { tag in
                        groupRow(tag)
                    }
                    Button {
                        newGroupName = ""
                        showCreateGroup = true
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                            .frame(minHeight: 44)
                    }
                } header: {
                    Text(verbatim: user.uname)
                }
                .disabled(!editor.canEdit)
            }
            .listRowBackground(AppFill.card)
            .readableFormWidth(.ambientBrowse)
            .navigationTitle(Text("Set Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        editor.save {
                            onSaved()
                            dismiss()
                        }
                    } label: {
                        if editor.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(!editor.canEdit)
                }
            }
            .overlay {
                if !editor.isCurrentSource {
                    ContentUnavailableView(
                        "Sign In Required",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if !editor.loaded {
                    if editor.isLoading || !editor.attempted {
                        ProgressView()
                    } else {
                        MessageLoadFailureView(message: editor.loadError) {
                            Task { await editor.load() }
                        }
                    }
                }
            }
            .alert(Text("New Group"), isPresented: $showCreateGroup) {
                TextField(String(localized: "Group Name"), text: $newGroupName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { editor.createGroup(named: newGroupName) }
            }
            .alert("Operation Failed", isPresented: Binding(
                get: { editor.actionError != nil },
                set: { if !$0 { editor.clearActionError() } }
            )) {
                Button("OK") { editor.clearActionError() }
            } message: {
                Text(editor.actionError ?? "")
            }
        }
        .accentContentBoundary()
        .task { await editor.load() }
        .onChange(of: AccountManager.shared.identityRevision) { _, _ in
            editor.retire()
            dismiss()
        }
        .onDisappear { editor.retire() }
    }

    private func groupRow(_ tag: RelationTag) -> some View {
        Button {
            editor.toggle(tag.tagid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tag.tagid == -10 ? "star.fill" : "folder")
                    .font(.subheadline)
                    .foregroundStyle(tag.tagid == -10 ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                Text(FollowingListView.tagDisplayName(tag))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: editor.selection.contains(tag.tagid) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(editor.selection.contains(tag.tagid)
                        ? AnyShapeStyle(.biliAccent)
                        : AnyShapeStyle(.quaternary))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(editor.selection.contains(tag.tagid) ? .isSelected : [])
    }
}

@MainActor
@Observable
private final class FollowGroupEditor {
    private(set) var allTags: [RelationTag]
    private(set) var selection: Set<Int> = []
    private(set) var loaded = false
    private(set) var attempted = false
    private(set) var loadError: String?
    private(set) var actionError: String?
    private(set) var isSaving = false
    private var loadID: UUID?
    private var actionID: UUID?
    private var retired = false
    @ObservationIgnored private var loadWork: Task<Void, Never>?
    @ObservationIgnored private var actionWork: Task<Void, Never>?
    private let mid: Int
    private let account = AccountManager.shared.activeMid
    private let revision = AccountManager.shared.identityRevision
    private let session = AuthManager.shared.sessionGeneration

    init(mid: Int, tags: [RelationTag]) {
        self.mid = mid
        allTags = tags
    }

    var isCurrentSource: Bool {
        !retired && AuthManager.shared.isLoggedIn && account != nil
            && AccountManager.shared.activeMid == account
            && AuthManager.shared.dedeUserID == account
            && AccountManager.shared.identityRevision == revision
            && AuthManager.shared.sessionGeneration == session
    }

    var isLoading: Bool { loadID != nil }
    var canEdit: Bool { loaded && isCurrentSource && loadID == nil && actionID == nil }

    func load() async {
        guard !Task.isCancelled, isCurrentSource, !loaded, actionID == nil,
              loadID == nil || loadWork?.isCancelled == true else { return }
        loadWork?.cancel()
        let id = UUID()
        loadID = id
        attempted = true
        loadError = nil
        let work = Task { await fetchInitial(id) }
        loadWork = work
        defer {
            if loadID == id {
                loadID = nil
                loadWork = nil
            }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func fetchInitial(_ id: UUID) async {
        guard isCurrentLoad(id) else { return }
        do {
            let catalogue = try await UserAPI.getRelationTags()
            guard isCurrentLoad(id) else { return }
            let membership = try await UserAPI.getUserRelationTags(fid: mid)
            guard isCurrentLoad(id) else { return }
            var membershipIDs: Set<Int> = []
            for key in membership.keys {
                guard let tagID = Int(key) else {
                    throw BiliError.decodingFailed(DecodingError.dataCorrupted(.init(
                        codingPath: [], debugDescription: "Invalid following group identifier"
                    )))
                }
                membershipIDs.insert(tagID)
            }
            // Retain every server membership, even IDs omitted by the catalogue.
            // An empty set is editable only after both reads actually succeed.
            allTags = catalogue
            selection = membershipIDs
            loaded = true
        } catch {
            guard isCurrentLoad(id), !BiliAPIRetryPolicy.isCancellation(error),
                  (error as? BiliError)?.isCancellation != true else { return }
            loadError = error.localizedDescription
        }
    }

    private func isCurrentLoad(_ id: UUID) -> Bool {
        !Task.isCancelled && isCurrentSource && loadID == id
    }

    func toggle(_ tagID: Int) {
        guard canEdit else { return }
        if selection.contains(tagID) {
            selection.remove(tagID)
        } else {
            selection.insert(tagID)
        }
    }

    func save(onSaved: @escaping () -> Void) {
        guard canEdit else { return }
        let id = UUID()
        var target = selection
        if target.count > 1 { target.remove(0) }
        actionID = id
        actionError = nil
        isSaving = true
        actionWork = Task { await performSave(id, target: target, onSaved: onSaved) }
    }

    private func performSave(_ id: UUID, target: Set<Int>, onSaved: () -> Void) async {
        defer { finishAction(id) }
        guard isCurrentAction(id) else { return }
        do {
            _ = try await UserAPI.setRelationTags(mids: [mid], tagids: Array(target))
            guard isCurrentAction(id) else { return }
            onSaved()
        } catch {
            guard isCurrentAction(id), !error.isCancellation else { return }
            actionError = error.localizedDescription
        }
    }

    func createGroup(named input: String) {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !name.isEmpty else { return }
        let id = UUID()
        actionID = id
        actionError = nil
        actionWork = Task { await performCreate(id, name: name) }
    }

    private func performCreate(_ id: UUID, name: String) async {
        defer { finishAction(id) }
        guard isCurrentAction(id) else { return }
        do {
            let created = try await UserAPI.createRelationTag(name: name)
            guard isCurrentAction(id) else { return }
            if let tagID = created.tagid {
                if !allTags.contains(where: { $0.tagid == tagID }) {
                    allTags.append(RelationTag(tagid: tagID, name: name, count: 0))
                }
                selection.insert(tagID)
            }
            // A failed catalogue refresh never replays an accepted create POST.
            let catalogue = try await UserAPI.getRelationTags()
            guard isCurrentAction(id) else { return }
            allTags = catalogue
        } catch {
            guard isCurrentAction(id), !error.isCancellation else { return }
            actionError = error.localizedDescription
        }
    }

    private func isCurrentAction(_ id: UUID) -> Bool {
        !Task.isCancelled && isCurrentSource && actionID == id
    }

    private func finishAction(_ id: UUID) {
        guard actionID == id else { return }
        actionID = nil
        actionWork = nil
        isSaving = false
    }

    func clearActionError() { actionError = nil }

    func retire() {
        retired = true
        loadWork?.cancel()
        actionWork?.cancel()
        loadID = nil
        actionID = nil
        loadWork = nil
        actionWork = nil
        isSaving = false
    }
}
