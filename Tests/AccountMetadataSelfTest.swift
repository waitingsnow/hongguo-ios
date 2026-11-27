import Foundation

@main
struct AccountMetadataSelfTest {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw HGError.message("FAIL " + label) }
        }
        func drama(_ id: String, title: String = "剧集", cover: String = "", summary: String = "", count: Int = 0) -> Drama {
            Drama(id: id, title: title, coverURL: cover, summary: summary, episodeCount: count)
        }

        let id = "7702763145030290457"
        let placeholder = drama(id, title: "剧集 \(id)")
        let known = drama(id, title: "缓存剧名", cover: "https://p.example/known.jpg", summary: "缓存简介", count: 80)
        let removed = drama("999", title: "已移除作品")
        let failed = try await AccountRules.completeListMetadata([placeholder], previous: [known, removed]) { _ in
            ["data": [["book_id": "999", "book_name": "无关作品"]]]
        }
        try check(failed == [known], "sparse-refresh-retains-known-fields-without-restoring-removed-rows")
        let freshShelf = drama(id, title: "收藏剧名")
        let titleOnly = try await AccountRules.completeListMetadata([freshShelf], previous: [known]) { _ in
            ["data": [["book_id": id, "book_name": "剧集 \(id)"], ["book_id": id, "book_name": "详情剧名"]]]
        }
        try check(titleOnly == [drama(id, title: "详情剧名", cover: known.coverURL, summary: known.summary, count: 80)],
                  "title-only-details-preserve-cached-poster-summary-and-count")

        let nested = try ProtocolJSON.object(Data(#"""
            {"data":[
                {"video_data":{"series_id":7702763145030290457,"series_title":"剧集","title":"单集简介",
                    "series_cover":{"url_list":["https://user@p.example/bad.jpg","http:\\/\\/p.example\\/nested.jpg"]},
                    "series_intro":"嵌套简介","episode_count":82}},
                {"book_id":"999","video_data":{"series_id":7702763145030290457,"series_title":"错误作品"}},
                {"book_id":7702763145030290457,"video_data":{"series_id":"999","series_title":"错误作品"}}
            ]}
            """#.utf8))
        let coverOnly = try await AccountRules.completeListMetadata([freshShelf], previous: [known]) { _ in nested }
        try check(coverOnly == [drama(id, title: freshShelf.title, cover: "https://p.example/nested.jpg", summary: "嵌套简介", count: 82)],
                  "nested-metadata-keeps-exact-id-and-current-title-and-rejects-credentialed-urls")
        let nestedTitle = AccountRules.detailMetadata(["data": [["book_id": id, "video_data": ["book_name": "嵌套剧名"]]]], requested: [id])
        try check(nestedTitle[id]?.title == "嵌套剧名", "nested-canonical-title-fills-blank-outer-title")

        let values = (1...120).map { drama(String($0)) }
        let duplicate = drama("1")
        var batches = [[String]]()
        let pages = try await AccountRules.completeListMetadata(values + [duplicate], previous: [drama("51", title: "缓存第51部")]) { ids in
            batches.append(ids)
            if ids.first == "51" { return [:] }
            return ["data": ids.map { ["book_id": $0, "book_name": "第\($0)部"] }]
        }
        try check(batches.map(\.count) == [50, 50, 20] && batches.flatMap { $0 } == values.map(\.id)
                  && pages.map(\.id) == (values + [duplicate]).map(\.id), "bounded-deduplicated-requests-and-unchanged-output-order")
        try check(pages[50].title == "缓存第51部" && pages[100].title == "第101部" && pages.last == pages.first,
                  "unavailable-batch-keeps-cache-and-allows-later-batches")

        let older = LibraryEntry(drama: known, episodeID: "801", episodeIndex: 2, position: 5, updatedAt: Date(timeIntervalSince1970: 100))
        let recent = LibraryEntry(drama: placeholder, episodeID: "802", episodeIndex: 12, position: 34, updatedAt: Date(timeIntervalSince1970: 200))
        var expected = recent
        expected.drama = known
        try check(AccountRules.mergeHistory(progress: [recent], records: [older]) == [expected],
                  "older-record-fills-metadata-without-rewinding-progress")
        try check(AccountRules.mergeHistory(progress: [older], records: [recent]) == [expected],
                  "newer-record-keeps-fields-from-older-progress")

        let task = Task {
            try await AccountRules.completeListMetadata(values, previous: []) { ids in
                try check(ids.first == "1", "cancelled-enrichment-started-another-batch")
                withUnsafeCurrentTask { $0?.cancel() }
                return [:]
            }
        }
        do {
            _ = try await task.value
            throw HGError.message("FAIL cancelled-enrichment-returned")
        } catch is CancellationError { }
        print("PASS account metadata: scoped cache, nested details, partial batches, history progress and cancellation")
    }
}
