import SwiftUI

struct MusicDetailView: View {
    let destination: MusicDestination
    var onNavigateAway: (() -> Void)?

    var body: some View {
        MusicDetailContent(destination: destination, onNavigateAway: onNavigateAway)
            .id(destination.reference)
    }
}

struct MusicDetailSheet: View {
    let destination: MusicDestination
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            MusicDetailView(destination: destination, onNavigateAway: dismiss)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss)
                    }
                }
        }
        .appAdaptiveSheet(padSizing: .form)
        .accentContentBoundary()
    }
}

private struct MusicDetailContent: View {
    let destination: MusicDestination
    var onNavigateAway: (() -> Void)?
    @State private var model: MusicDetailViewModel
    @Environment(AppCoordinator.self) private var coordinator

    init(destination: MusicDestination, onNavigateAway: (() -> Void)? = nil) {
        self.destination = destination
        self.onNavigateAway = onNavigateAway
        _model = State(initialValue: MusicDetailViewModel(reference: destination.reference))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.detail?.musicTitle ?? destination.titleSeed ?? String(localized: "Music"))
                    .appFont(.screenTitle)
                    .textSelection(.enabled)
                if let detail = model.detail {
                    detailContent(detail)
                } else if model.isLoading || !model.hasAttemptedLoad {
                    ProgressView().accessibilityLabel("Loading music information")
                } else {
                    failureContent
                }
                Button {
                    onNavigateAway?()
                    coordinator.navigate(to: .inAppWeb(destination.officialURL))
                } label: {
                    Label("Open Official Page", systemImage: "globe")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Music")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private func detailContent(_ detail: MusicDetail) -> some View {
        if let cover = nonblank(detail.mvCover) {
            CoverImage(urlString: cover)
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .frame(maxWidth: 400)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
        artists(detail)
        if let album = nonblank(detail.album) {
            metadata("Album", value: album)
        }
        if let source = nonblank(detail.musicSource) {
            metadata("Music Source", value: source)
        }
        if let videoID = detail.mvVideoID {
            Button {
                let target = VideoRouteTarget(
                    videoID: videoID,
                    preview: PortraitPagingPreview(
                        title: nonblank(detail.musicTitle) ?? destination.titleSeed ?? "",
                        coverURL: nonblank(detail.mvCover) ?? "",
                        ownerName: detail.artistText ?? ""
                    )
                )
                if coordinator.navigateToVideo(target) {
                    onNavigateAway?()
                }
            } label: {
                Label("Watch MV", systemImage: "play.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func artists(_ detail: MusicDetail) -> some View {
        let artists = detail.displayArtists
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Artists").appFont(.sectionTitle)
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    if let mid = artist.mid, mid > 0 {
                        Button {
                            onNavigateAway?()
                            coordinator.navigate(to: .userSpace(mid))
                        } label: {
                            artistRow(artist)
                        }
                        .buttonStyle(.plain)
                    } else {
                        artistRow(artist)
                    }
                }
            }
        } else if let text = detail.artistText {
            metadata("Artists", value: text)
        }
    }

    private func artistRow(_ artist: MusicDetail.Artist) -> some View {
        HStack(spacing: 12) {
            AvatarImage(urlString: artist.face, size: 40)
            Text(artist.name ?? "").appFont(.screenOwner).foregroundStyle(.primary)
            if (artist.mid ?? 0) > 0 {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func metadata(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(.sectionTitle)
            Text(value).appFont(.screenSummary).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var failureContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Label("Load Failed", systemImage: "exclamationmark.triangle")
                Text(failure).appFont(.screenSummary).foregroundStyle(.secondary)
            }
            Button("Retry") { Task { await model.load() } }.buttonStyle(.borderedProminent)
        }
    }

    private func nonblank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
