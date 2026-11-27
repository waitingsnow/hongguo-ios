// SPDX-License-Identifier: GPL-3.0-only
// Rank boards and search suggestions adapted from tsukiyo-zero/hongguoTV kotlin-tv/core RankBrowser.kt, ComicRank.kt and
// ContentRepository.kt at f22bb3f (2026-11-03) through hongguo-android. Only the page's serialized data is read; no script runs.
import Foundation
import CoreFoundation

enum RankBoard: String, CaseIterable, Identifiable, Sendable {
    case all = "hot-drama", real = "hot-real-drama", comic = "hot-comic-drama", ai = "hot-ai-drama"
    var id: String { rawValue }
    var label: String { switch self { case .all: return "综合"; case .real: return "真人剧"; case .comic: return "漫剧"; case .ai: return "AI 剧" } }
    var loader: String { "rank_\(rawValue)/page" }
}

struct RankEntry: Identifiable, Sendable {
    var id: String { drama.id }
    let drama: Drama
    let rank: Int
    let heat: String
}

struct RankPage: Sendable {
    let entries: [RankEntry]
    let page: Int
    let totalPages: Int
}

/// Public website data. Anonymous: no account cookie is ever sent here.
enum WebsiteCatalog {
    static let base = "https://hongguoduanju.com"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    /// The site answers ?page=1 with a redirect to the bare address, and redirects are not followed here.
    static func rankURL(_ board: RankBoard, page: Int) -> URL { URL(string: "\(base)/rank/\(board.rawValue)" + (page > 1 ? "?page=\(page)" : ""))! }

    static func suggestionURL(query: String, webID: String) -> URL? {
        var components = URLComponents(string: base + "/incent_resource/suggestion")
        components?.queryItems = [URLQueryItem(name: "app_id", value: "8662"), URLQueryItem(name: "web_id", value: webID), URLQueryItem(name: "query", value: query)]
        return components?.url
    }

    static func parseRank(_ html: String, board: RankBoard, page: Int) throws -> RankPage {
        if let payload = inlineRankContent(html, board: board) { return try rankPage(payload, page: page) }
        for pattern in ["data-fn-args='([^']*)'", "data-fn-args=\"([^\"]*)\""] {
            let expression = try NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html), let data = decodeEntities(String(html[range])).data(using: .utf8),
                      let args = (try? JSONSerialization.jsonObject(with: data)) as? [Any], args.count >= 3,
                      args[0] as? String == board.loader, args[1] as? String == "content" else { continue }
                let payload: [String: Any]
                if let object = args[2] as? [String: Any] { payload = object }
                else if let text = args[2] as? String, let object = try? ProtocolJSON.object(Data(text.utf8)) { payload = object }
                else { continue }
                return try rankPage(payload, page: page)
            }
        }
        throw HGError.message("榜单格式已变化")
    }

    /// Since 2026-11-11 the site renders the loader result inline as `_ROUTER_DATA = {...}`
    /// (loaderData["rank_<route>/page"].content); the streamed data-fn-args payload is gone (Android issue #8).
    static func inlineRankContent(_ html: String, board: RankBoard) -> [String: Any]? {
        inlineRouterValue(html) { loaders in
            ProtocolJSON.dictionary(loaders[board.loader])["content"] as? [String: Any]
        }
    }

    static func inlineRouterValue<Value>(_ html: String, select: ([String: Any]) -> Value?) -> Value? {
        let marker = Array("_ROUTER_DATA = ".utf8), bytes = Array(html.utf8)
        var at = 0
        while let start = firstIndex(of: marker, in: bytes, from: at) {
            let open = start + marker.count
            at = open
            guard open < bytes.count, bytes[open] == UInt8(ascii: "{"), let close = objectEnd(bytes, from: open),
                  let root = try? ProtocolJSON.object(Data(bytes[open...close])) else { continue }
            if let value = select(ProtocolJSON.dictionary(root["loaderData"])) { return value }
        }
        return nil
    }

    private static func firstIndex(of marker: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !marker.isEmpty, bytes.count >= marker.count, from <= bytes.count - marker.count else { return nil }
        for index in from...(bytes.count - marker.count) where bytes[index] == marker[0] && Array(bytes[index..<index + marker.count]) == marker { return index }
        return nil
    }

    /// Index of the brace closing the JSON object that starts at `open`; strings and escapes are skipped.
    private static func objectEnd(_ bytes: [UInt8], from open: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        for index in open..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private static func rankPage(_ payload: [String: Any], page: Int) throws -> RankPage {
        guard ProtocolJSON.bool(payload["isSuccess"]) else { throw HGError.message("榜单暂不可用") }
        guard let rows = payload["rankList"] as? [Any] else { throw HGError.message("榜单格式已变化") }
        let paging = ProtocolJSON.dictionary(payload["pagination"]), total = ProtocolJSON.integer(paging["totalPages"])
        guard total >= 1, paging["pageNum"] == nil || ProtocolJSON.integer(paging["pageNum"]) == page else { throw HGError.message("榜单分页信息异常") }
        var seen = Set<String>(), entries = [RankEntry]()
        for value in rows {
            let row = ProtocolJSON.dictionary(value), series = ProtocolJSON.text(row["seriesId"]), id = series.isEmpty ? ProtocolJSON.text(row["id"]) : series
            let title = ProtocolJSON.text(row["title"])
            guard ProtocolJSON.identifier(id) != nil, !title.isEmpty, seen.insert(id).inserted else { continue }
            let count = row["episodeCount"] != nil ? ProtocolJSON.integer(row["episodeCount"]) : ProtocolJSON.array(row["episodeVids"]).count
            entries.append(RankEntry(drama: Drama(id: id, title: title, coverURL: ProtocolJSON.text(row["cover"]), summary: ProtocolJSON.text(row["description"]), episodeCount: max(0, count)),
                                     rank: max(0, ProtocolJSON.integer(row["rank"])), heat: ProtocolJSON.text(row["heatText"])))
        }
        return RankPage(entries: entries, page: page, totalPages: min(total, 100))
    }

    static func parseSuggestions(_ object: [String: Any]) -> [String] {
        var seen = Set<String>(), result = [String]()
        for value in ProtocolJSON.array(object["suggest_list"]) {
            let row = ProtocolJSON.dictionary(value), name = ProtocolJSON.text(row["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = name.isEmpty ? ProtocolJSON.text(ProtocolJSON.array(row["display_words"]).first).trimmingCharacters(in: .whitespacesAndNewlines) : name
            guard !text.isEmpty, text.count <= 80, seen.insert(text).inserted, result.count < 8 else { continue }
            result.append(text)
        }
        return result
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum PublicEpisodeSource {
    enum Failure: LocalizedError {
        case unavailable, rateLimited, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "官网暂未向访客提供本集完整片源"
            case .rateLimited: return "官网请求过于频繁，请稍后再试"
            case .invalidResponse: return "官网未返回有效的分集播放信息"
            case .http(let status): return "官网片源请求失败（HTTP \(status)）"
            }
        }
    }

    struct EpisodeInfo {
        let duration: WebEpisodeDuration
        let shortSide: Int
    }

    static func track(seriesID: String, episodeID: String, session: URLSession) async throws -> VideoTrack {
        guard ProtocolJSON.identifier(seriesID) != nil, ProtocolJSON.identifier(episodeID) != nil else { throw Failure.invalidResponse }
        let page = URL(string: "\(WebsiteCatalog.base)/player/\(seriesID)/\(episodeID)")!
        let html = try await load(URLRequest(url: page), session: session, limit: 4 * 1024 * 1024)
        let info = try episodeInfo(html: String(decoding: html, as: UTF8.self), seriesID: seriesID, episodeID: episodeID)

        var request = URLRequest(url: URL(string: WebsiteCatalog.base + "/api/video/protected/fallback-play-info")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try ProtocolJSON.data(["item_id": episodeID])
        let data = try await load(request, session: session, limit: 64 * 1024)
        return try track(response: data, info: info)
    }

    static func episodeInfo(html: String, seriesID: String, episodeID: String) throws -> EpisodeInfo {
        guard let page = WebsiteCatalog.inlineRouterValue(html, select: { $0["player_(series_id)/(vid)/page"] as? [String: Any] }),
              boolean(page["isSuccess"]) == true,
              ProtocolJSON.identifier(page["series_id"]) == seriesID, ProtocolJSON.identifier(page["vid"]) == episodeID,
              let series = page["seriesDetail"] as? [String: Any], ProtocolJSON.identifier(series["series_id"]) == seriesID
        else { throw Failure.invalidResponse }
        let access = ProtocolJSON.dictionary(page["req"])
        let ids = ProtocolJSON.array(series["vid_list"])
        let count = series["accessible_episode_cnt"]
        guard boolean(access["pcLoginRequired"]) == false, boolean(access["pcAuthenticatedPlayback"]) == false,
              boolean(count) == nil, let accessibleCount = Int(ProtocolJSON.text(count)),
              let index = ids.firstIndex(where: { ProtocolJSON.identifier($0) == episodeID }), index < accessibleCount
        else { throw Failure.unavailable }
        try DramaAPI.checkPlaybackBusinessRejection(page)
        try DramaAPI.checkPlaybackBusinessRejection(access)

        let metadata = ProtocolJSON.dictionary(page["publicVideoSeo"])
        guard boolean(metadata["available"]) == true else { return EpisodeInfo(duration: .unlisted, shortSide: 0) }
        guard ProtocolJSON.identifier(metadata["seriesId"]) == seriesID, ProtocolJSON.identifier(metadata["itemId"]) == episodeID,
              let duration = Double(ProtocolJSON.text(metadata["durationSeconds"])), duration.isFinite, duration > 0
        else { throw Failure.invalidResponse }
        let pixels = min(ProtocolJSON.integer(metadata["width"]), ProtocolJSON.integer(metadata["height"]))
        return EpisodeInfo(duration: .declared(duration), shortSide: max(0, pixels))
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func track(response: Data, info: EpisodeInfo, now: Date = Date()) throws -> VideoTrack {
        guard let json = try? ProtocolJSON.object(response) else { throw Failure.invalidResponse }
        let status = ProtocolJSON.dictionary(json["base_resp"])
        try DramaAPI.checkPlaybackBusinessRejection(json)
        try DramaAPI.checkPlaybackBusinessRejection(status)
        let code = status["StatusCode"] ?? json["code"]
        guard boolean(code) == nil, ProtocolJSON.text(code) == "0",
              let rawURL = json["main_url"] as? String, let url = URL(string: rawURL),
              VideoTrack.allowsMediaURL(url) else { throw Failure.invalidResponse }
        if let value = json["url_expire"] {
            guard let expiry = Double(ProtocolJSON.text(value)), expiry.isFinite,
                  expiry > now.timeIntervalSince1970 + 5 else { throw Failure.invalidResponse }
        }
        let definition = info.shortSide > 0 ? "网页 \(info.shortSide)P" : "网页片源"
        return VideoTrack(url: url, spadeA: "", encrypted: false, definition: definition,
                          shortSide: info.shortSide, expectedDuration: info.duration)
    }

    private static func load(_ input: URLRequest, session: URLSession, limit: Int) async throws -> Data {
        var request = input
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        let (data, _) = try await PlaybackResponseReader.read(DramaAPI.boundedRequest(request), session: session, limit: limit) { http in
            guard http.url == input.url else { throw Failure.unavailable }
            do { try DramaAPI.checkPlaybackHTTP(http) }
            catch let refusal as DramaAPI.PlaybackRefusal { throw refusal.isBackoff ? Failure.rateLimited : Failure.unavailable }
            if http.statusCode == 404 { throw Failure.unavailable }
            guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        }
        try Task.checkCancellation()
        return data
    }
}
