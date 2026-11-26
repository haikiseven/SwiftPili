import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - Video Chapter Model

struct VideoChapter: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let from: TimeInterval
    // swiftlint:disable:next identifier_name
    let to: TimeInterval
    let imgURL: String?

    var duration: TimeInterval { max(0, to - from) }

    static func from(viewPoints: [PlayerV2Info.ViewPoint]?) -> [VideoChapter] {
        guard let viewPoints, !viewPoints.isEmpty else { return [] }
        struct RawChapter {
            let title: String
            let from: TimeInterval
            let endTime: TimeInterval
            let imgURL: String?
        }

        let valid: [RawChapter] = viewPoints.compactMap { point in
            guard let rawTitle = point.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty,
                  let from = point.from, from.isFinite, from >= 0 else {
                return nil
            }
            let resolvedEnd: TimeInterval
            if let rawTo = point.to, rawTo.isFinite, rawTo > from {
                resolvedEnd = rawTo
            } else {
                resolvedEnd = from
            }
            let normalizedImg = point.imgURL.flatMap(PlayerAmbientStoryboardFrame.normalizedURL)
            return RawChapter(title: rawTitle, from: from, endTime: resolvedEnd, imgURL: normalizedImg)
        }
        guard !valid.isEmpty else { return [] }

        let sorted = valid.sorted { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            return lhs.endTime < rhs.endTime
        }

        return sorted.indices.map { idx in
            let item = sorted[idx]
            let resolvedTo: TimeInterval
            if item.endTime > item.from {
                resolvedTo = item.endTime
            } else if idx + 1 < sorted.count, sorted[idx + 1].from > item.from {
                resolvedTo = sorted[idx + 1].from
            } else {
                resolvedTo = item.from
            }
            return VideoChapter(
                id: "\(idx)-\(Int(item.from.rounded()))-\(item.title)",
                title: item.title,
                from: item.from,
                to: resolvedTo,
                imgURL: item.imgURL
            )
        }
    }

    static func activeChapter(at time: TimeInterval, in chapters: [VideoChapter]) -> VideoChapter? {
        guard !chapters.isEmpty, time.isFinite, time >= 0 else { return nil }
        var low = 0
        var high = chapters.count - 1
        var candidateIndex: Int?
        while low <= high {
            let mid = low + (high - low) / 2
            if chapters[mid].from <= time {
                candidateIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let idx = candidateIndex else { return nil }
        let candidate = chapters[idx]
        if candidate.to > candidate.from, time >= candidate.to {
            let isLastChapter = idx == chapters.count - 1
            if isLastChapter, time <= candidate.to + 1.0 {
                return candidate
            }
            return nil
        }
        return candidate
    }

    static func tickFractions(for chapters: [VideoChapter], duration: TimeInterval) -> [Double] {
        guard duration.isFinite, duration > 0, !chapters.isEmpty else { return [] }
        return chapters.compactMap { chapter in
            let fraction = chapter.from / duration
            guard fraction > 0.005, fraction < 0.995 else { return nil }
            return fraction
        }
    }
}

// MARK: - Observable Chapter Cache Store

@MainActor
@Observable
final class PlayerChapterStore {
    struct ContentKey: Hashable, Sendable {
        let aid: Int
        let cid: Int
    }

    static let shared = PlayerChapterStore()
    private static let maxCachedVideos = 64

    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var cache: [ContentKey: [VideoChapter]] = [:]
    @ObservationIgnored private var insertionOrder: [ContentKey] = []

    init() {}

    func record(_ chapters: [VideoChapter], aid: Int, cid: Int) {
        guard aid > 0, cid > 0 else { return }
        let key = ContentKey(aid: aid, cid: cid)
        if cache[key] == chapters { return }
        if cache[key] == nil {
            insertionOrder.append(key)
            while insertionOrder.count > Self.maxCachedVideos {
                let evicted = insertionOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[key] = chapters
        revision &+= 1
    }

    func chapters(aid: Int, cid: Int) -> [VideoChapter] {
        _ = revision
        guard aid > 0, cid > 0 else { return [] }
        return cache[ContentKey(aid: aid, cid: cid)] ?? []
    }

    func clear() {
        guard !cache.isEmpty else { return }
        cache.removeAll()
        insertionOrder.removeAll()
        revision &+= 1
    }
}

extension PlayerViewModel {
    var videoChapters: [VideoChapter] {
        guard mode.usesOnlineVODServices, let aid = currentAid, let cid = currentCid else {
            return []
        }
        return PlayerChapterStore.shared.chapters(aid: aid, cid: cid)
    }

    func chapter(at time: TimeInterval) -> VideoChapter? {
        VideoChapter.activeChapter(at: time, in: videoChapters)
    }
}

// MARK: - Player Chapter Jump Sheet

struct PlayerChapterSheet: View {
    let chapters: [VideoChapter]
    let currentTime: TimeInterval
    let onSelect: (VideoChapter) -> Void

    @Environment(\.dismiss) private var dismiss

    private var activeChapterID: String? {
        VideoChapter.activeChapter(at: currentTime, in: chapters)?.id
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    let isActive = chapter.id == activeChapterID
                    chapterRow(chapter, isActive: isActive)
                        .id(chapter.id)
                        .listRowBackground(isActive ? Color.biliAccent.opacity(0.10) : nil)
                }
                .listStyle(.plain)
                .onAppear {
                    if let activeChapterID {
                        proxy.scrollTo(activeChapterID, anchor: .center)
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .appAdaptiveSheet(compactDetents: [.medium], padSizing: .form)
        .accentContentBoundary()
    }

    private func chapterRow(_ chapter: VideoChapter, isActive: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(chapter)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                chapterLeadingView(chapter, isActive: isActive)

                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .font(.subheadline.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.biliAccent : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if chapter.duration > 0 {
                        Text(FormatUtils.duration(Int(chapter.duration)))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isActive {
                    Image(systemName: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.biliAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func chapterLeadingView(_ chapter: VideoChapter, isActive: Bool) -> some View {
        if let imgURL = chapter.imgURL {
            CoverImage(
                urlString: imgURL,
                displaySize: CGSize(width: 88, height: 50),
                contentMode: .fill
            )
            .frame(width: 88, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.thumbnail, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(FormatUtils.duration(Int(chapter.from)))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        } else {
            Text(FormatUtils.duration(Int(chapter.from)))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isActive ? Color.biliAccent : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isActive ? Color.biliAccent.opacity(0.14) : AppFill.inset,
                    in: Capsule()
                )
        }
    }
}
