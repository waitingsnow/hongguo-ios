import CoreFoundation
import Foundation

struct EpisodeComment: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let author: String
    var singleLineText: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

struct EpisodeCommentPreview: Equatable, Sendable {
    let items: [EpisodeComment]
    let totalCount: Int?
    var previewCount: Int { items.count }
    var hasDisplayableComments: Bool { !items.isEmpty }
    var displayCount: Int? { totalCount ?? (hasDisplayableComments ? previewCount : nil) }
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

    actor PreviewCache {
        private struct Entry {
            let preview: EpisodeCommentPreview
            let expiresAt: ContinuousClock.Instant
        }

        private let lifetime: Duration
        private let capacity: Int
        private var entries: [URL: Entry] = [:]
        private var pending: [URL: Task<EpisodeCommentPreview, Error>] = [:]

        init(lifetime: Duration = .seconds(30), capacity: Int = 32) {
            self.lifetime = lifetime
            self.capacity = capacity
        }

        func preview(for url: URL, load: @escaping @Sendable () async throws -> EpisodeCommentPreview) async throws -> EpisodeCommentPreview {
            try Task.checkCancellation()
            if let entry = entries[url], entry.expiresAt > ContinuousClock.now { return entry.preview }
            entries[url] = nil

            let task: Task<EpisodeCommentPreview, Error>
            if let ongoing = pending[url] {
                task = ongoing
            } else {
                task = Task {
                    defer { pending[url] = nil }
                    let preview = try await load()
                    store(preview, for: url)
                    return preview
                }
                pending[url] = task
            }
            let preview = try await task.value
            try Task.checkCancellation()
            return preview
        }

        private func store(_ preview: EpisodeCommentPreview, for url: URL) {
            guard capacity > 0, preview.previewCount <= 32 else { return }
            let textBytes = preview.items.reduce(0) { $0 + $1.text.utf8.count + $1.author.utf8.count }
            guard textBytes <= 16 * 1024 else { return }
            if entries.count >= capacity, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                entries[oldest] = nil
            }
            entries[url] = Entry(preview: preview, expiresAt: ContinuousClock.now.advanced(by: lifetime))
        }
    }

    private static let maximumPageBytes = 8 * 1024 * 1024
    private static let cache = PreviewCache()
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
        try await preview(seriesID: seriesID, episodeID: episodeID).items
    }

    static func preview(seriesID: String, episodeID: String) async throws -> EpisodeCommentPreview {
        guard let url = shareURL(seriesID: seriesID, episodeID: episodeID) else {
            throw ReadError.invalidIdentifier
        }
        return try await cache.preview(for: url) {
            try await fetchPreview(url, seriesID: seriesID, episodeID: episodeID)
        }
    }

    private static func fetchPreview(_ url: URL, seriesID: String, episodeID: String) async throws -> EpisodeCommentPreview {
        let (bytes, response) = try await session.bytes(for: publicPageRequest(url))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ReadError.unexpectedPage }
        try validateStatus(http, episodeID: episodeID)
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

    static func publicPageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(WebsiteCatalog.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func validateStatus(_ response: HTTPURLResponse, episodeID: String) throws {
        switch response.statusCode {
        case 200: return
        case 404, 410: throw ReadError.unavailable
        case 300..<400:
            if let location = response.value(forHTTPHeaderField: "Location"),
               let redirect = URL(string: location, relativeTo: response.url)?.absoluteURL,
               redirect.scheme == "https", redirect.host == response.url?.host, redirect.port == response.url?.port,
               let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
               components.queryItems?.first(where: { $0.name == "pc_locked_episode" })?.value == episodeID {
                throw ReadError.unavailable
            }
            throw ReadError.httpStatus(response.statusCode)
        default: throw ReadError.httpStatus(response.statusCode)
        }
    }

    static func parse(_ html: String, seriesID: String, episodeID: String) throws -> EpisodeCommentPreview {
        let page = WebsiteCatalog.inlineRouterValue(html) { $0["player_(series_id)/(vid)/page"] as? [String: Any] }
        guard let page,
              ProtocolJSON.identifier(ProtocolJSON.dictionary(page["seriesDetail"])["series_id"]) == seriesID,
              ProtocolJSON.identifier(page["vid"]) == episodeID else { throw ReadError.unexpectedPage }
        guard ProtocolJSON.bool(page["isSuccess"], default: true) else { throw ReadError.unavailable }
        let social = ProtocolJSON.dictionary(page["episodeSocialInfo"])
        let preview = ProtocolJSON.dictionary(social["reviews"])
        guard let publishedReviews = preview["reviews"], !(publishedReviews is NSNull) else {
            throw ReadError.unavailable
        }
        guard let reviews = publishedReviews as? [Any] else { throw ReadError.unexpectedPage }

        var seen = Set<String>()
        var containsTextField = false
        let items: [EpisodeComment] = try reviews.compactMap { value in
            guard let review = value as? [String: Any], let content = review["content"] as? String else { return nil }
            containsTextField = true
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let author = review["user_name"] as? String ?? ""
            let created = ProtocolJSON.text(review["create_time"])
            let identity = try ProtocolJSON.data([seriesID, episodeID, author, created, text])
            let id = HGCrypto.sha256(identity).hexString
            guard seen.insert(id).inserted else { return nil }
            return EpisodeComment(id: id, text: text, author: author)
        }
        guard reviews.isEmpty || containsTextField else { throw ReadError.unexpectedPage }
        let rawTotal = preview["total_count"]
        let isBoolean = (rawTotal as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        let total = isBoolean ? nil : Int(ProtocolJSON.text(rawTotal))
        let validTotal = total.flatMap { count in count >= items.count && (count > 0 || reviews.isEmpty) ? count : nil }
        return EpisodeCommentPreview(items: items, totalCount: validTotal)
    }
}
