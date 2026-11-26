import SwiftUI
import UniformTypeIdentifiers

struct LocalContentFilterSettingsView: View {
    private let store = LocalContentFilterStore.shared

    @State private var showExporter = false
    @State private var exportDocument = LocalContentFilterDocument(data: Data())
    @State private var showImporter = false
    @State private var showClearConfirm = false
    @State private var statusAlertTitle: String?
    @State private var statusAlertMessage: String?

    var body: some View {
        List {
            Group {
                primaryControlsSection
                localRulesSection
                cloudFiltersSection
                backupAndResetSection
            }
            .listRowBackground(AppFill.card)
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Local Content Filter")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "SwiftPili-ContentFilters"
        ) { result in
            switch result {
            case .success:
                AppNoticeCenter.shared.show(String(localized: "Filter rules exported"), style: .success)
            case .failure(let error):
                statusAlertTitle = String(localized: "Export Failed")
                statusAlertMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .confirmationDialog(
            "Clear all local filter rules?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All Local Rules", role: .destructive) {
                store.clearAllRules()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes all locally blocked UPs, videos, and keyword rules on this device. "
                + "Your Bilibili account blacklist is not affected."
            )
        }
        .alert(
            statusAlertTitle ?? "",
            isPresented: Binding(
                get: { statusAlertMessage != nil },
                set: {
                    if !$0 {
                        statusAlertTitle = nil
                        statusAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusAlertMessage ?? "")
        }
    }

    private var primaryControlsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.isEnabled },
                set: { store.isEnabled = $0 }
            )) {
                settingsLabel("Enable Filter", symbol: "line.3.horizontal.decrease.circle")
            }

            Toggle(isOn: Binding(
                get: { store.collapseFilteredComments },
                set: { store.collapseFilteredComments = $0 }
            )) {
                settingsLabel("Collapse Filtered Comments", symbol: "rectangle.compress.vertical")
            }
        }
    }

    private var localRulesSection: some View {
        Section("Local Filter Rules") {
            NavigationLink {
                LocalBlockedUPsSettingsView()
            } label: {
                LabeledContent {
                    Text(verbatim: "\(store.blockedUPs.count)").monospacedDigit()
                } label: {
                    settingsLabel("Blocked UPs", symbol: "person.slash")
                }
            }

            NavigationLink {
                LocalBlockedVideosSettingsView()
            } label: {
                LabeledContent {
                    Text(verbatim: "\(store.blockedVideos.count)").monospacedDigit()
                } label: {
                    settingsLabel("Blocked Videos", symbol: "eye.slash")
                }
            }

            NavigationLink {
                LocalKeywordRulesSettingsView(kind: .title)
            } label: {
                LabeledContent {
                    Text(verbatim: "\(store.titleKeywords.filter(\.isEnabled).count)/\(store.titleKeywords.count)")
                        .monospacedDigit()
                } label: {
                    settingsLabel("Title Keywords", symbol: "text.magnifyingglass")
                }
            }

            NavigationLink {
                LocalKeywordRulesSettingsView(kind: .comment)
            } label: {
                LabeledContent {
                    Text(verbatim: "\(store.commentKeywords.filter(\.isEnabled).count)/\(store.commentKeywords.count)")
                        .monospacedDigit()
                } label: {
                    settingsLabel("Comment Keywords", symbol: "text.bubble")
                }
            }
        }
    }

    private var cloudFiltersSection: some View {
        Section("Bilibili Cloud Filters") {
            NavigationLink {
                BilibiliCloudDanmakuFiltersView()
            } label: {
                settingsLabel("Import Cloud Filters", symbol: "icloud.and.arrow.down")
            }
        }
    }

    private var backupAndResetSection: some View {
        Section("Backup & Management") {
            Button {
                do {
                    exportDocument = LocalContentFilterDocument(data: try store.exportJSONData())
                    showExporter = true
                } catch {
                    statusAlertTitle = String(localized: "Export Failed")
                    statusAlertMessage = error.localizedDescription
                }
            } label: {
                settingsLabel("Export Rules (JSON)", symbol: "square.and.arrow.up")
                    .foregroundStyle(.primary)
            }

            Button {
                showImporter = true
            } label: {
                settingsLabel("Import Rules (JSON)", symbol: "square.and.arrow.down")
                    .foregroundStyle(.primary)
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label {
                    Text("Clear All Local Rules").foregroundStyle(.red)
                } icon: {
                    SettingsIcon(symbol: "trash", tint: .red)
                }
            }
            .disabled(store.totalRuleCount == 0)
        }
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            statusAlertTitle = String(localized: "Import Failed")
            statusAlertMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try store.importJSONData(try Data(contentsOf: url), merge: true)
                let notice = summary.totalAdded > 0
                    ? String(format: String(localized: "Imported %lld local filter rules"), summary.totalAdded)
                    : String(localized: "All rules in the file already exist locally")
                AppNoticeCenter.shared.show(notice, style: .success)
            } catch {
                statusAlertTitle = String(localized: "Import Failed")
                statusAlertMessage = error.localizedDescription
            }
        }
    }

    private func settingsLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label { Text(title) } icon: { SettingsIcon(symbol: symbol) }
    }
}

// MARK: - Blocked UPs Subview

private struct LocalBlockedUPsSettingsView: View {
    private let store = LocalContentFilterStore.shared
    @Environment(AppCoordinator.self) private var coordinator

    @State private var showAddAlert = false
    @State private var manualMID = ""
    @State private var manualName = ""

    var body: some View {
        List {
            if !store.blockedUPs.isEmpty {
                Section {
                    ForEach(store.blockedUPs) { entry in
                        HStack(spacing: AppSpacing.m) {
                            Button {
                                coordinator.navigate(to: .userSpace(entry.mid))
                            } label: {
                                HStack(spacing: AppSpacing.m) {
                                    AvatarImage(urlString: entry.face ?? "", size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(verbatim: "UID \(entry.mid)")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: AppSpacing.s)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.unblockUP(mid: entry.mid)
                            } label: {
                                Text("Remove")
                                    .appFont(.controlLabel)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, AppSpacing.m)
                                    .padding(.vertical, 6)
                                    .background(AppFill.inset, in: Capsule())
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.unblockUP(mid: entry.mid)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(AppFill.card)
            }
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Blocked UPs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    manualMID = ""
                    manualName = ""
                    showAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Add UP by UID"))
            }
        }
        .overlay {
            if store.blockedUPs.isEmpty {
                ContentUnavailableView(
                    "No Locally Blocked UPs",
                    systemImage: "person.slash"
                )
            }
        }
        .alert("Add UP by UID", isPresented: $showAddAlert) {
            TextField(String(localized: "UID (numbers)"), text: $manualMID)
                .keyboardType(.numberPad)
            TextField(String(localized: "Display name (optional)"), text: $manualName)
            Button("Add") {
                if let parsed = Int(manualMID.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
                    store.blockUP(mid: parsed, name: manualName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Blocked Videos Subview

private struct LocalBlockedVideosSettingsView: View {
    private let store = LocalContentFilterStore.shared
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        List {
            if !store.blockedVideos.isEmpty {
                Section {
                    ForEach(store.blockedVideos) { entry in
                        HStack(spacing: AppSpacing.m) {
                            Button {
                                if let target = VideoRouteTarget.make(
                                    bvid: entry.bvid,
                                    aid: entry.aid,
                                    title: entry.title,
                                    ownerName: entry.ownerName ?? ""
                                ) {
                                    _ = coordinator.navigateToVideo(target)
                                }
                            } label: {
                                videoEntryLabels(entry)
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.unblockVideo(id: entry.id)
                            } label: {
                                Text("Remove")
                                    .appFont(.controlLabel)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, AppSpacing.m)
                                    .padding(.vertical, 6)
                                    .background(AppFill.inset, in: Capsule())
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.unblockVideo(id: entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(AppFill.card)
            }
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Blocked Videos")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.blockedVideos.isEmpty {
                ContentUnavailableView(
                    "No Locally Blocked Videos",
                    systemImage: "eye.slash"
                )
            }
        }
    }

    private func videoEntryLabels(_ entry: BlockedVideoEntry) -> some View {
        let fallbackID = entry.bvid ?? entry.aid.map { "av\($0)" } ?? entry.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(entry.title.isEmpty ? fallbackID : entry.title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                if let owner = entry.ownerName, !owner.isEmpty {
                    Text(owner).lineLimit(1)
                }
                if let bvid = entry.bvid, !bvid.isEmpty {
                    Text(verbatim: bvid).monospacedDigit()
                } else if let aid = entry.aid {
                    Text(verbatim: "av\(aid)").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Keyword Rules Subview

private struct LocalKeywordRulesSettingsView: View {
    enum Kind {
        case title
        case comment

        var navigationTitle: LocalizedStringKey {
            self == .title ? "Title Keywords" : "Comment Keywords"
        }

        var fieldPlaceholder: LocalizedStringKey {
            self == .title ? "Add video title keyword or regex" : "Add comment keyword or regex"
        }
    }

    let kind: Kind
    private let store = LocalContentFilterStore.shared

    @State private var draftPattern = ""
    @State private var draftIsRegex = false

    private var rules: [KeywordFilterRule] {
        kind == .title ? store.titleKeywords : store.commentKeywords
    }

    private var trimmedDraft: String {
        draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftRegexError: String? {
        guard draftIsRegex else { return nil }
        return LocalContentFilterStore.validateRegex(trimmedDraft)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: AppSpacing.s) {
                    TextField(kind.fieldPlaceholder, text: $draftPattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(addRule)
                    Button("Add", action: addRule)
                        .disabled(trimmedDraft.isEmpty || draftRegexError != nil)
                }
                Toggle("Regular Expression", isOn: $draftIsRegex)
                if let draftRegexError {
                    Label(draftRegexError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .listRowBackground(AppFill.card)

            if !rules.isEmpty {
                Section("Saved Rules") {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { removeRule(id: rule.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listRowBackground(AppFill.card)
            }
        }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle(kind.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ruleRow(_ rule: KeywordFilterRule) -> some View {
        let invalidRegex = rule.isRegex ? LocalContentFilterStore.validateRegex(rule.pattern) : nil
        return Toggle(isOn: Binding(
            get: { rule.isEnabled },
            set: { toggleRule(id: rule.id, isEnabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: rule.pattern)
                        .font(rule.isRegex ? .body.monospaced() : .body)
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        .lineLimit(2)
                    if rule.isRegex {
                        Text("Regex")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.biliAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.biliAccent.opacity(0.12), in: Capsule())
                    }
                }
                if let invalidRegex {
                    Label(invalidRegex, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func addRule() {
        let pattern = trimmedDraft
        guard !pattern.isEmpty, draftRegexError == nil else { return }
        if kind == .title {
            _ = store.addTitleKeyword(pattern, isRegex: draftIsRegex)
        } else {
            _ = store.addCommentKeyword(pattern, isRegex: draftIsRegex)
        }
        draftPattern = ""
    }

    private func removeRule(id: UUID) {
        if kind == .title { store.removeTitleKeyword(id: id) } else { store.removeCommentKeyword(id: id) }
    }

    private func toggleRule(id: UUID, isEnabled: Bool) {
        if kind == .title {
            store.toggleTitleKeyword(id: id, isEnabled: isEnabled)
        } else {
            store.toggleCommentKeyword(id: id, isEnabled: isEnabled)
        }
    }
}

// MARK: - Bilibili Cloud Danmaku Filter Viewer & Importer

private struct BilibiliCloudDanmakuFiltersView: View {
    private let store = LocalContentFilterStore.shared

    @State private var rules: [CloudDanmakuFilterRule] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var importTarget: CloudFilterImportTarget = .both

    private var importableRules: [CloudDanmakuFilterRule] {
        rules.filter(\.isImportableAsKeywordRule)
    }

    var body: some View {
        List {
            if AuthManager.shared.isLoggedIn, !rules.isEmpty {
                Section {
                    Picker("Import Into", selection: $importTarget) {
                        Text("Comment Keywords").tag(CloudFilterImportTarget.comment)
                        Text("Title Keywords").tag(CloudFilterImportTarget.title)
                        Text("Both").tag(CloudFilterImportTarget.both)
                    }
                    Button { importAllRules() } label: {
                        HStack {
                            Label("Import to Local Filter", systemImage: "square.and.arrow.down.on.square")
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(verbatim: "\(importableRules.count)")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(importableRules.isEmpty)
                }
                .listRowBackground(AppFill.card)

                Section("Cloud Rules") {
                    ForEach(rules) { rule in cloudRuleRow(rule) }
                }
                .listRowBackground(AppFill.card)
            }
        }
        .refreshable { await loadCloudFilters() }
        .readableFormWidth(.ambientBrowse)
        .accentContentBoundary()
        .navigationTitle("Bilibili Cloud Filters")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyStateOverlay }
        .task {
            if AuthManager.shared.isLoggedIn, !hasLoaded {
                await loadCloudFilters()
            }
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if !AuthManager.shared.isLoggedIn {
            ContentUnavailableView(
                "Sign In Required",
                systemImage: "person.crop.circle"
            )
        } else if isLoading && rules.isEmpty {
            ProgressView()
        } else if let loadError, rules.isEmpty {
            MessageLoadFailureView(message: loadError) {
                Task { await loadCloudFilters() }
            }
        } else if hasLoaded && rules.isEmpty {
            ContentUnavailableView(
                "No Cloud Filter Rules",
                systemImage: "icloud"
            )
        }
    }

    private func cloudRuleRow(_ rule: CloudDanmakuFilterRule) -> some View {
        let alreadyImported = rule.isImportableAsKeywordRule
            && store.hasKeywordRule(pattern: rule.filter, isRegex: rule.isRegex, in: importTarget)
        return HStack(spacing: AppSpacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ruleKindBadge(rule)
                    Text(verbatim: rule.filter)
                        .font(rule.isRegex ? .body.monospaced() : .body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if let comment = rule.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
                    Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if rule.isImportableAsKeywordRule {
                if alreadyImported {
                    Label("Imported", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button { importSingleRule(rule) } label: {
                        Text("Import")
                            .appFont(.controlLabel)
                            .fontWeight(.semibold)
                            .padding(.horizontal, AppSpacing.m)
                            .padding(.vertical, 6)
                            .background(Color.biliAccent.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.biliAccent)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Danmaku Only").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func ruleKindBadge(_ rule: CloudDanmakuFilterRule) -> some View {
        let spec: (LocalizedStringKey, Color) = switch rule.kind {
        case .keyword: ("Keyword", .blue)
        case .regex: ("Regex", .purple)
        case .userHash: ("User Hash", .orange)
        case nil: ("Other", .secondary)
        }
        return Text(spec.0)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(spec.1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(spec.1.opacity(0.12), in: Capsule())
    }

    private func loadCloudFilters() async {
        guard AuthManager.shared.isLoggedIn, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            rules = try await DanmakuAPI.getUserFilters()
            hasLoaded = true
        } catch {
            if !BiliAPIRetryPolicy.isCancellation(error) {
                loadError = error.localizedDescription
                PlayerLog.log("[ContentFilter] load cloud danmaku filters failed: \(error)")
            }
        }
    }

    private func importAllRules() {
        let added = store.importCloudDanmakuFilters(importableRules, target: importTarget)
        let message = added > 0
            ? String(format: String(localized: "Imported %lld local filter rules"), added)
            : String(localized: "All cloud rules already exist in local filter")
        AppNoticeCenter.shared.show(message, style: .success)
    }

    private func importSingleRule(_ rule: CloudDanmakuFilterRule) {
        if store.importCloudDanmakuFilters([rule], target: importTarget) > 0 {
            AppNoticeCenter.shared.show(String(localized: "Imported to local filter"), style: .success)
        }
    }
}
