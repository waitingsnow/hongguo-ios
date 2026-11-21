import Foundation

struct EpisodeComment: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let author: String
}

enum EpisodeDiscussionAPI {
    enum ReadError: LocalizedError, Equatable {
        case invalidIdentifier
        case unavailable
        case unexpectedPage
        case responseTooLarge
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier: return "剧集或分集编号无效。"
            case .unavailable: return "官网未开放本集评论预览。"
            case .unexpectedPage: return "官网返回的分集或评论格式不匹配。"
            case .responseTooLarge: return "官网返回的评论页面过大。"
            case .httpStatus(let status): return "官网评论读取失败（HTTP \(status)）。"
            }
        }
    }

    private static let maximumPageBytes = 8 * 1024 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: ProtocolSessionDelegate(), delegateQueue: nil)
    }()

    static func shareURL(seriesID: String, episodeID: String) -> URL? {
        guard ProtocolJSON.identifier(seriesID) != nil, ProtocolJSON.identifier(episodeID) != nil else { return nil }
        return URL(string: "\(WebsiteCatalog.base)/player/\(seriesID)/\(episodeID)")
    }

    static func comments(seriesID: String, episodeID: String) async throws -> [EpisodeComment] {
        guard let url = shareURL(seriesID: seriesID, episodeID: episodeID) else {
            throw ReadError.invalidIdentifier
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ReadError.unexpectedPage }
        try validateStatus(http.statusCode)
        guard http.expectedContentLength <= maximumPageBytes else { throw ReadError.responseTooLarge }
        var body = Data()
        if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            guard body.count < maximumPageBytes else { throw ReadError.responseTooLarge }
            body.append(byte)
        }
        try Task.checkCancellation()
        return try parse(String(decoding: body, as: UTF8.self), seriesID: seriesID, episodeID: episodeID)
    }

    static func validateStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 300..<400, 401, 403, 404, 410: throw ReadError.unavailable
        default: throw ReadError.httpStatus(status)
        }
    }

    static func parse(_ html: String, seriesID: String, episodeID: String) throws -> [EpisodeComment] {
        let page = WebsiteCatalog.inlineRouterValue(html) { loaders in
            loaders.values.compactMap { $0 as? [String: Any] }.first {
                $0["seriesDetail"] != nil && $0["vid"] != nil
            }
        }
        guard let page,
              ProtocolJSON.identifier(ProtocolJSON.dictionary(page["seriesDetail"])["series_id"]) == seriesID,
              ProtocolJSON.identifier(page["vid"]) == episodeID else { throw ReadError.unexpectedPage }
        guard ProtocolJSON.bool(page["isSuccess"], default: true) else { throw ReadError.unavailable }
        let social = ProtocolJSON.dictionary(page["episodeSocialInfo"])
        guard let reviews = ProtocolJSON.dictionary(social["reviews"])["reviews"] as? [Any] else {
            throw ReadError.unavailable
        }

        var seen = Set<String>()
        return try reviews.compactMap { value in
            guard let review = value as? [String: Any], let content = review["content"] as? String else { return nil }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let author = review["user_name"] as? String ?? ""
            let created = ProtocolJSON.text(review["create_time"])
            let identity = try ProtocolJSON.data([seriesID, episodeID, author, created, text])
            let id = HGCrypto.sha256(identity).hexString
            guard seen.insert(id).inserted else { return nil }
            return EpisodeComment(id: id, text: text, author: author)
        }
    }
}
