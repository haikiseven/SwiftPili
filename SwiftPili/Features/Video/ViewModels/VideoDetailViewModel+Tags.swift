import Foundation

extension VideoDetailViewModel {
    struct TagSource: Equatable {
        let aid: Int
        let cid: Int
        let serial: UInt64
    }

    struct TagRequest {
        let source: TagSource
        let admits: @MainActor () -> Bool
    }

    struct TagPublication {
        let source: TagSource
        let tags: [VideoTag]
    }

    var currentTagSource: TagSource? {
        guard let source = tagPublication?.source,
              source.serial == tagRequestSerial,
              source.aid == videoInfo?.aid, source.cid == currentCid else { return nil }
        return source
    }

    func retireTags() {
        tagRequestSerial &+= 1
        tagPublication = nil
    }

    func prepareTags(
        aid: Int, cid: Int, retainsDisplay: Bool = false, admits: @escaping @MainActor () -> Bool
    ) -> TagRequest {
        if retainsDisplay {
            tagRequestSerial &+= 1
        } else {
            retireTags()
        }
        return TagRequest(source: TagSource(aid: aid, cid: cid, serial: tagRequestSerial), admits: admits)
    }

    func loadTags(_ request: TagRequest) async {
        guard !Task.isCancelled, request.source.serial == tagRequestSerial, request.admits() else { return }
        do {
            let fetched = try await VideoAPI.getTags(aid: request.source.aid, cid: request.source.cid)
            guard !Task.isCancelled, request.source.serial == tagRequestSerial, request.admits(),
                  videoInfo?.aid == request.source.aid, currentCid == request.source.cid else { return }
            tagPublication = TagPublication(source: request.source, tags: fetched)
        } catch {
            guard !Task.isCancelled, request.source.serial == tagRequestSerial, !error.isCancellation else { return }
            PlayerLog.log("[VideoDetailVM] tags failed: \(error)")
            tagPublication = nil
        }
    }

    func musicDestination(for tag: VideoTag, source: TagSource?) -> MusicDestination? {
        guard let source, source == currentTagSource, tags.contains(where: { $0.id == tag.id }), tag.isMusic else {
            return nil
        }
        let jump = tag.jumpUrl.flatMap { URL(string: $0.httpsURL) }
        let identified: MusicDestination?
        if let jump, case .resolved(.music(let destination), _) = BiliLinkResolver.resolve(url: jump) {
            identified = destination
        } else {
            identified = nil
        }
        let fieldID = tag.musicId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let musicID = fieldID?.isEmpty == false ? fieldID : identified?.reference.musicID,
              let reference = MusicReference(musicID: musicID, originAid: source.aid, originCid: source.cid)
        else { return nil }
        let original = identified?.reference.musicID == reference.musicID ? identified?.originalURL : nil
        return MusicDestination(reference: reference, titleSeed: tag.tagName, originalURL: original)
    }
}
