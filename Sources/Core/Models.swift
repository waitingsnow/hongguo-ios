// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Drama: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let coverURL: String
    let summary: String
    let episodeCount: Int
}

struct Episode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let index: Int
    let title: String
}

struct DramaDetail: Codable, Sendable {
    let drama: Drama
    let episodes: [Episode]
}

struct DramaPage: Sendable {
    let dramas: [Drama]
    let hasMore: Bool
    let nextOffset: Int
}

struct VideoTrack: Sendable {
    let url: URL
    let spadeA: String
    let encrypted: Bool
    let definition: String
    /// The picture's shorter side in pixels (720 for 720P), 0 when the server did not say.
    var shortSide: Int = 0
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
    let drama: Drama
    var episodeID: String
    var episodeIndex: Int
    var position: Double
    var updatedAt: Date
}
