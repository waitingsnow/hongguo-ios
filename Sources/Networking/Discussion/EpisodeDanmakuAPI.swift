import Foundation
import Openhongguo

struct EpisodeDanmaku: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let offsetMs: Int

    fileprivate init?(_ item: Danmaku) {
        guard item.offsetMs >= 0 else { return nil }
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytesRemaining = 1_024
        let bounded = trimmed.prefix(160).prefix { character in
            bytesRemaining -= character.utf8.count
            return bytesRemaining >= 0
        }
        guard !bounded.isEmpty else { return nil }
        let sourceID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceID.isEmpty || sourceID.utf8.count > 128 {
            let digest = HGCrypto.sha256(Data("\(item.offsetMs):\(trimmed)".utf8)).hexString
            id = "content:\(digest)"
        } else {
            id = "upstream:\(sourceID)"
        }
        text = String(bounded)
        offsetMs = item.offsetMs
    }
}

struct EpisodeDanmakuPage: Equatable, Sendable {
    let items: [EpisodeDanmaku]
    let startMs: Int
    let endMs: Int
    let totalCount: Int?
    let nextCursor: String?
    var hasMore: Bool { nextCursor != nil }

    init(_ page: DanmakuPage, previousCursor: String?) {
        let ordered = page.items.compactMap(EpisodeDanmaku.init).sorted {
            ($0.offsetMs, $0.id, $0.text) < ($1.offsetMs, $1.id, $1.text)
        }
        var seen = Set<String>()
        items = ordered.filter { seen.insert($0.id).inserted }
        startMs = page.startMs
        endMs = page.endMs
        totalCount = page.total > 0 ? page.total : nil
        nextCursor = page.hasMore && !page.cursor.isEmpty && page.cursor != previousCursor ? page.cursor : nil
    }
}

actor EpisodeDanmakuAPI {
    static let shared = EpisodeDanmakuAPI()

    enum Position: Sendable {
        case time(milliseconds: Int)
        case cursor(String)
    }

    enum ReadError: LocalizedError {
        case invalidIdentifier
        case invalidPosition

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier: return "剧集或分集编号无效。"
            case .invalidPosition: return "弹幕播放位置或分页游标无效。"
            }
        }
    }

    private var client: OpenhongguoClient?

    private init() {}

    func page(seriesID: String, episodeID: String, position: Position) async throws -> EpisodeDanmakuPage {
        try Task.checkCancellation()
        guard ProtocolJSON.identifier(seriesID) != nil, ProtocolJSON.identifier(episodeID) != nil else {
            throw ReadError.invalidIdentifier
        }
        let options: DanmakuOptions
        switch position {
        case .time(let milliseconds):
            guard milliseconds >= 0 else { throw ReadError.invalidPosition }
            options = DanmakuOptions(startMs: milliseconds)
        case .cursor(let cursor):
            guard !cursor.isEmpty else { throw ReadError.invalidPosition }
            options = DanmakuOptions(cursor: cursor)
        }
        let sdk = try client ?? OpenhongguoClient.create(options: ClientOptions(retryAttempts: 1, deviceResets: 0))
        client = sdk
        let page = try await sdk.listDanmaku(seriesID, episodeId: episodeID, options: options)
        try Task.checkCancellation()
        return EpisodeDanmakuPage(page, previousCursor: options.cursor)
    }
}
