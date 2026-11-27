// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Drama: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let coverURL: String
    let summary: String
    let episodeCount: Int

    func replacingMetadata(with metadata: Drama?) -> Drama {
        guard let metadata, metadata.id == id else { return self }
        return Drama(id: id,
                     title: metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : metadata.title,
                     coverURL: metadata.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? coverURL : metadata.coverURL,
                     summary: metadata.summary.isEmpty ? summary : metadata.summary,
                     episodeCount: metadata.episodeCount > 0 ? metadata.episodeCount : episodeCount)
    }
}

struct Episode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let index: Int
    let title: String
}

struct CastMember: Identifiable, Codable, Hashable, Sendable {
    var id: String { celebrityID.isEmpty ? nickname : celebrityID }
    let celebrityID: String
    let nickname: String
    let roleName: String
    let avatarURL: String
    let intro: String
}

struct DramaDetail: Codable, Sendable {
    let drama: Drama
    let episodes: [Episode]
    let cast: [CastMember]

    private enum CodingKeys: String, CodingKey {
        case drama, episodes, cast
    }

    init(drama: Drama, episodes: [Episode], cast: [CastMember] = []) {
        self.drama = drama
        self.episodes = episodes
        self.cast = cast
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drama = try values.decode(Drama.self, forKey: .drama)
        episodes = try values.decode([Episode].self, forKey: .episodes)
        cast = try values.decodeIfPresent([CastMember].self, forKey: .cast) ?? []
    }
}

struct DramaPage: Sendable {
    let dramas: [Drama]
    let hasMore: Bool
    let nextOffset: Int
}

enum WebEpisodeDuration: Equatable, Sendable {
    case declared(Double)
    case unlisted
}

struct VideoTrack: Sendable {
    let url: URL
    let spadeA: String
    let encrypted: Bool
    let definition: String
    /// The picture's shorter side in pixels (720 for 720P), 0 when the server did not say.
    var shortSide: Int = 0
    var expectedDuration: WebEpisodeDuration? = nil
    /// Extra addresses for the same clear rendition. Encrypted rows keep a single URL.
    var backupURLs: [URL] = []
}

extension VideoTrack {
    static func allowsMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        return ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// The player's 清晰度 choice. The server's ladder differs per episode, so this is a preference: the highest row at or
/// below it, otherwise the nearest one above.
enum VideoQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case p720 = "720p", p1080 = "1080p"
    var id: String { rawValue }
    var shortSide: Int { self == .p720 ? 720 : 1080 }
    var label: String { self == .p720 ? "720P" : "1080P" }
}

struct FilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct FilterGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let options: [FilterOption]
}

enum HGError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct LibraryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { drama.id }
    var drama: Drama
    var episodeID: String
    var episodeIndex: Int
    var position: Double
    var updatedAt: Date
}
