import Foundation
import Nuke

/// Last-known lists and drama details on disk, kept in Nuke's `DataCache` (LRU, size-limited), so launch and
/// re-opening a drama show content before the network answers. Network results always replace these copies.
final class ContentCache: @unchecked Sendable {
    static let shared = ContentCache()
    private let storage: DataCache?
    /// Bumped whenever a stored shape changes, so old snapshots are simply not found.
    private let schema = "v1"

    private convenience init() {
        self.init(storage: try? DataCache(name: "com.ooiua.hongguo.content"))
    }

    init(storage: DataCache?) {
        self.storage = storage
        storage?.sizeLimit = 40 * 1024 * 1024
    }

    private struct Envelope<Value: Codable>: Codable { let savedAt: Date; let value: Value }

    func value<Value: Codable>(_ type: Value.Type, for key: String) -> (value: Value, age: TimeInterval, savedAt: Date)? {
        guard let data = storage?.cachedData(for: schema + "." + key),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else { return nil }
        return (envelope.value, max(0, Date().timeIntervalSince(envelope.savedAt)), envelope.savedAt)
    }

    func store<Value: Codable>(_ value: Value, for key: String, savedAt: Date = .now) {
        guard let data = try? JSONEncoder().encode(Envelope(savedAt: savedAt, value: value)) else { return }
        storage?.storeData(data, for: schema + "." + key)
    }

    func catalog(for key: String) -> CatalogCacheEntry? {
        if let saved = value(CatalogSnapshot.self, for: "catalog.v2." + key) {
            guard saved.age < CatalogCacheEntry.keptFor else { return nil }
            return CatalogCacheEntry(snapshot: saved.value, firstPageAt: saved.savedAt)
        }
        if let legacy = value(CatalogSnapshot.self, for: "catalog." + key),
           legacy.age < CatalogCacheEntry.keptFor, !legacy.value.dramas.isEmpty {
            return CatalogCacheEntry(snapshot: CatalogSnapshot(dramas: legacy.value.dramas, hasMore: false, nextOffset: 0),
                                     firstPageAt: nil)
        }
        return nil
    }

    func storeCatalog(_ snapshot: CatalogSnapshot, for key: String, firstPageAt: Date) {
        store(snapshot, for: "catalog.v2." + key, savedAt: firstPageAt)
    }
}

struct CatalogCacheEntry {
    static let freshFor: TimeInterval = 30 * 60
    static let keptFor: TimeInterval = 7 * 24 * 3600
    let snapshot: CatalogSnapshot
    let firstPageAt: Date?

    static func isFresh(_ firstPageAt: Date?) -> Bool {
        guard let firstPageAt else { return false }
        return Date().timeIntervalSince(firstPageAt) < freshFor
    }
}

struct CatalogSnapshot: Codable {
    let dramas: [Drama]
    let hasMore: Bool
    let nextOffset: Int

    static func updated(after page: DramaPage, from offset: Int, previous: Self?) -> Self? {
        guard offset == 0 || previous?.nextOffset == offset else { return nil }
        var dramas = offset == 0 ? [] : previous?.dramas ?? []
        var known = Set(dramas.map(\.id))
        dramas += page.dramas.filter { known.insert($0.id).inserted }
        guard dramas.count <= 200 else { return nil }
        let hasMore = page.hasMore && !page.dramas.isEmpty && page.nextOffset > offset
        return Self(dramas: dramas, hasMore: hasMore, nextOffset: page.nextOffset)
    }
}

/// Drama details (title, cover and the episode list) with a disk copy. A fresh copy is used as is; an older one is
/// the fallback when the network fails.
@MainActor
enum DramaDetails {
    nonisolated static let freshFor: TimeInterval = 30 * 60

    static func cached(_ id: String) -> (detail: DramaDetail, age: TimeInterval)? {
        guard let entry = ContentCache.shared.value(DramaDetail.self, for: "detail." + id), !entry.value.episodes.isEmpty else { return nil }
        return (entry.value, entry.age)
    }

    static func load(_ drama: Drama, maxAge: TimeInterval = freshFor) async throws -> DramaDetail {
        let saved = cached(drama.id)
        if let saved, saved.age < maxAge { return saved.detail }
        do {
            let detail = try await DramaAPI.shared.detail(drama: drama)
            remember(detail)
            return detail
        } catch is CancellationError { throw CancellationError()
        } catch {
            if let saved { return saved.detail }
            throw error
        }
    }

    static func remember(_ detail: DramaDetail) {
        guard !detail.episodes.isEmpty else { return }
        ContentCache.shared.store(detail, for: "detail." + detail.drama.id)
    }
}
