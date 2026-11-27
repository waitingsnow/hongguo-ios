import Foundation
import Nuke

@main
struct CatalogCacheSelfTest {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try DataCache(path: directory)
        let cache = ContentCache(storage: disk)
        let firstPageAt = Date.now.addingTimeInterval(-CatalogCacheEntry.freshFor - 60)
        let firstPage = page(1...18, next: 20)
        let savedFirst = try required(CatalogSnapshot.updated(after: firstPage, from: 0, previous: nil))
        let savedSecond = try required(CatalogSnapshot.updated(after: page(18...36, next: 41), from: 20, previous: savedFirst))
        cache.storeCatalog(savedSecond, for: "home.latest", firstPageAt: firstPageAt)
        cache.storeCatalog(savedFirst, for: "home.comic", firstPageAt: .now)
        cache.storeCatalog(savedFirst, for: "home.guess.account:one", firstPageAt: .now)
        cache.storeCatalog(savedSecond, for: "home.guess.anonymous", firstPageAt: .now)
        cache.storeCatalog(savedFirst, for: "discover.short_play",
                           firstPageAt: .now.addingTimeInterval(-CatalogCacheEntry.keptFor - 60))
        cache.store(savedSecond, for: "catalog.home.recommend")
        let empty = try required(CatalogSnapshot.updated(after: DramaPage(dramas: [], hasMore: false, nextOffset: 0),
                                                        from: 0, previous: savedSecond))
        cache.store(empty, for: "catalog.discover.ai_series")
        cache.storeCatalog(empty, for: "discover.ai_series", firstPageAt: .now)
        let episodes = [Episode(id: "101", index: 1, title: "第1集")]
        let legacyDrama = firstPage.dramas[0]
        cache.store(LegacyDetail(drama: legacyDrama, episodes: episodes), for: "detail." + legacyDrama.id)
        let castDrama = firstPage.dramas[1]
        let cast = [CastMember(celebrityID: "7001", nickname: "范祺", roleName: "沈如锦",
                               avatarURL: "https://example.test/avatar.jpg", intro: "代表作《测试》")]
        cache.store(DramaDetail(drama: castDrama, episodes: episodes, cast: cast), for: "detail." + castDrama.id)
        disk.flush()

        let restarted = ContentCache(storage: try DataCache(path: directory))
        let legacyDetail = try required(restarted.value(DramaDetail.self, for: "detail." + legacyDrama.id)).value
        precondition(legacyDetail.drama == legacyDrama && legacyDetail.episodes == episodes && legacyDetail.cast.isEmpty)
        let castDetail = try required(restarted.value(DramaDetail.self, for: "detail." + castDrama.id)).value
        precondition(castDetail.drama == castDrama && castDetail.episodes == episodes && castDetail.cast == cast)
        let stale = try required(restarted.catalog(for: "home.latest"))
        precondition(stale.snapshot.dramas.count == 36 && stale.snapshot.nextOffset == 41 && stale.snapshot.hasMore)
        precondition(stale.firstPageAt == firstPageAt && !CatalogCacheEntry.isFresh(stale.firstPageAt))
        precondition(restarted.catalog(for: "discover.short_play") == nil)
        precondition(restarted.catalog(for: "home.guess.account:two") == nil)
        let account = try required(restarted.catalog(for: "home.guess.account:one"))
        precondition(CatalogCacheEntry.isFresh(account.firstPageAt))
        let legacy = try required(restarted.catalog(for: "home.recommend"))
        precondition(legacy.snapshot.dramas == savedSecond.dramas && legacy.firstPageAt == nil)
        precondition(!legacy.snapshot.hasMore && legacy.snapshot.nextOffset == 0)
        let emptyAfterRestart = try required(restarted.catalog(for: "discover.ai_series"))
        precondition(emptyAfterRestart.snapshot.dramas.isEmpty && !emptyAfterRestart.snapshot.hasMore)
        precondition(CatalogCacheEntry.isFresh(emptyAfterRestart.firstPageAt))

        let coldAccount = GuessFeedAccess(hasCredentials: true, profileID: "one", verifiedOwner: nil)
        let owner = UUID()
        let verified = GuessFeedAccess(hasCredentials: true, profileID: "one", verifiedOwner: owner)
        let unknown = GuessFeedAccess(hasCredentials: true, profileID: "", verifiedOwner: nil)
        let signedOut = GuessFeedAccess(hasCredentials: false, profileID: "one", verifiedOwner: nil)
        let switched = GuessFeedAccess(hasCredentials: true, profileID: "two", verifiedOwner: UUID())
        func cached(_ access: GuessFeedAccess) -> CatalogSnapshot? {
            access.historyKey.flatMap { restarted.catalog(for: "home.guess." + $0)?.snapshot }
        }
        precondition(cached(coldAccount)?.dramas == savedFirst.dramas && !coldAccount.canRequest && coldAccount.owner == nil)
        precondition(cached(verified)?.dramas == savedFirst.dramas && verified.canRequest && verified.owner == owner)
        precondition(cached(unknown) == nil && !unknown.canRequest)
        precondition(cached(signedOut)?.dramas == savedSecond.dramas && signedOut.canRequest && signedOut.owner == nil)
        precondition(cached(switched) == nil && switched.canRequest && switched.owner != owner)

        let nearLimit = try required(CatalogSnapshot.updated(after: page(1...198, next: 210), from: 0, previous: nil))
        precondition(CatalogSnapshot.updated(after: page(199...216, next: 230), from: 210, previous: nearLimit) == nil)
        precondition(CatalogSnapshot.updated(after: page(217...218, next: 232), from: 230, previous: nearLimit) == nil)
        precondition(nearLimit.nextOffset == 210 && nearLimit.hasMore)
        let stopped = try required(CatalogSnapshot.updated(after: page(199...200, next: 210), from: 210, previous: nearLimit))
        precondition(!stopped.hasMore)

        let comic = try required(restarted.catalog(for: "home.comic"))
        let pager = ComicRankPager(cachedPrefix: comic.snapshot.dramas) { excluded in
            precondition(excluded == (1...18).map(String.init))
            return ComicRankBatch(dramas: page(19...36, next: 36).dramas, hasMore: true)
        }
        let continued = try await pager.page(offset: comic.snapshot.dramas.count)
        precondition(continued.dramas.map(\.id) == (19...36).map(String.init))
        precondition(continued.hasMore && continued.nextOffset == 36)
        print("Catalog cache checks passed: restart, account verification/switch isolation, freshness, expiry, legacy, empty results, pagination boundary, comic resume and detail cast")
    }

    private struct LegacyDetail: Codable {
        let drama: Drama
        let episodes: [Episode]
    }

    private static func page(_ range: ClosedRange<Int>, next: Int) -> DramaPage {
        DramaPage(dramas: range.map { Drama(id: String($0), title: "Drama \($0)", coverURL: "", summary: "", episodeCount: 1) },
                  hasMore: true, nextOffset: next)
    }

    private static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
