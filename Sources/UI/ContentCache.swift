import Foundation
import Nuke

/// Last-known lists and drama details on disk, kept in Nuke's `DataCache` (LRU, size-limited), so launch and
/// re-opening a drama show content before the network answers. Network results always replace these copies.
final class ContentCache: @unchecked Sendable {
    static let shared = ContentCache()
    private let storage: DataCache?
    /// Bumped whenever a stored shape changes, so old snapshots are simply not found.
    private let schema = "v1"

    private init() {
        storage = try? DataCache(name: "com.ooiua.hongguo.content")
        storage?.sizeLimit = 40 * 1024 * 1024
    }

    private struct Envelope<Value: Codable>: Codable { let savedAt: Date; let value: Value }

    func value<Value: Codable>(_ type: Value.Type, for key: String) -> (value: Value, age: TimeInterval)? {
        guard let data = storage?.cachedData(for: schema + "." + key),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else { return nil }
        return (envelope.value, max(0, Date().timeIntervalSince(envelope.savedAt)))
    }

    func store<Value: Codable>(_ value: Value, for key: String) {
        guard let data = try? JSONEncoder().encode(Envelope(savedAt: Date(), value: value)) else { return }
        storage?.storeData(data, for: schema + "." + key)
    }
}

struct CatalogSnapshot: Codable {
    let dramas: [Drama]
    let hasMore: Bool
    let nextOffset: Int
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
