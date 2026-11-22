import Foundation
import SwiftData

/// Legacy pre-migration store schema kept solely to stamp unversioned
/// on-device stores before upgrading to `StorageSchemaV2`.
enum StorageSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [WatchHistoryItem.self, SearchHistoryItem.self, DownloadedVideo.self]
    }

    /// Retired local watch-history table (`CB-5`), retained in V1 only so
    /// existing stores can drop it cleanly during migration to V2.
    @Model
    final class WatchHistoryItem {
        var aid: Int
        var bvid: String
        var title: String
        var coverURL: String
        var ownerName: String
        var ownerMid: Int
        var duration: Int
        var progress: Int
        var watchedAt: Date

        init(
            aid: Int,
            bvid: String,
            title: String,
            coverURL: String,
            ownerName: String,
            ownerMid: Int,
            duration: Int,
            progress: Int = 0,
            watchedAt: Date = .now
        ) {
            self.aid = aid
            self.bvid = bvid
            self.title = title
            self.coverURL = coverURL
            self.ownerName = ownerName
            self.ownerMid = ownerMid
            self.duration = duration
            self.progress = progress
            self.watchedAt = watchedAt
        }
    }
}

/// Active persistence schema after dropping the unused `WatchHistoryItem` table.
enum StorageSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SearchHistoryItem.self, DownloadedVideo.self]
    }
}

enum StorageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [StorageSchemaV1.self, StorageSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: StorageSchemaV1.self, toVersion: StorageSchemaV2.self)]
    }
}

enum AppStorageContainer {
    static func makeModelContainer() throws -> ModelContainer {
        let v2Schema = Schema(versionedSchema: StorageSchemaV2.self)
        do {
            return try ModelContainer(for: v2Schema, migrationPlan: StorageMigrationPlan.self)
        } catch {
            // Existing installs created before VersionedSchema have an unversioned
            // store (`CoreData 134504`); opening once with V1 stamps `1.0.0` so
            // the staged V1 -> V2 lightweight migration can proceed cleanly.
            let v1Schema = Schema(versionedSchema: StorageSchemaV1.self)
            _ = try ModelContainer(for: v1Schema)
            return try ModelContainer(for: v2Schema, migrationPlan: StorageMigrationPlan.self)
        }
    }
}

@Model
final class SearchHistoryItem {
    var keyword: String
    var searchedAt: Date

    init(keyword: String, searchedAt: Date = .now) {
        self.keyword = keyword
        self.searchedAt = searchedAt
    }
}
