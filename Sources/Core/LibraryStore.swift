// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    private static let previousEpisodeLimit = 32
    @Published private(set) var favorites: [LibraryEntry] = []
    @Published private(set) var history: [LibraryEntry] = []
    @Published private(set) var storageError: String?
    @Published private(set) var storageLocked = false
    private let fileURL: URL
    private var lastWrite = Date.distantPast
    private var needsSave = false
    private var previousEpisodes: [String: [EpisodePosition]] = [:]

    private struct EpisodePosition: Codable {
        let id: String
        let position: Double
    }

    private struct Snapshot: Codable {
        var version: Int = 1
        var favorites: [LibraryEntry]
        var history: [LibraryEntry]
        var previousEpisodes: [String: [EpisodePosition]]? = nil
    }

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hongguo", isDirectory: true)
        fileURL = root.appendingPathComponent("library-v1.json")
        reload()
    }

    /// Retry after a temporary storage failure. Failed loads never authorize replacing the original file.
    func reload() {
        if needsSave {
            save()
            guard !needsSave else { return }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 4 * 1024 * 1024 else { throw HGError.message("本机片单文件过大") }
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                favorites = normalized(snapshot.favorites)
                history = normalized(snapshot.history)
                previousEpisodes = [:]
                for entry in history {
                    let positions = snapshot.previousEpisodes?[entry.id] ?? []
                    let valid = positions.lazy.filter {
                        !$0.id.isEmpty && $0.id.count <= 128 && $0.position.isFinite && $0.position >= 0
                    }.prefix(Self.previousEpisodeLimit)
                    if !valid.isEmpty { previousEpisodes[entry.id] = Array(valid) }
                }
            }
            storageLocked = false; storageError = nil
        } catch {
            storageLocked = true
            storageError = "本机片单读取失败，原文件已保留，已暂停写入。请稍后重新读取。"
        }
    }

    func isFavorite(_ drama: Drama) -> Bool { favorites.contains { $0.id == drama.id } }

    func toggleFavorite(_ drama: Drama) {
        guard !storageLocked else { return }
        if isFavorite(drama) { favorites.removeAll { $0.id == drama.id } }
        else {
            let old = progress(for: drama.id)
            favorites.insert(LibraryEntry(drama: drama, episodeID: old?.episodeID ?? "", episodeIndex: old?.episodeIndex ?? 1,
                                          position: old?.position ?? 0, updatedAt: Date()), at: 0)
            favorites = normalized(favorites)
        }
        save()
    }

    /// Called only after the playback view confirms a rendered frame.
    func record(drama: Drama, episode: Episode, position: Double) {
        guard !storageLocked else { return }
        guard !drama.id.isEmpty, !episode.id.isEmpty, position.isFinite else { return }
        let entry = LibraryEntry(drama: drama, episodeID: episode.id, episodeIndex: episode.index,
                                 position: max(0, position), updatedAt: Date())
        if let previous = history.first(where: { $0.id == drama.id }), !previous.episodeID.isEmpty, previous.episodeID != episode.id {
            var positions = previousEpisodes[drama.id] ?? []
            positions.removeAll { $0.id == previous.episodeID || $0.id == episode.id }
            positions.insert(EpisodePosition(id: previous.episodeID, position: previous.position), at: 0)
            previousEpisodes[drama.id] = Array(positions.prefix(Self.previousEpisodeLimit))
        }
        history.removeAll { $0.id == drama.id }
        history.insert(entry, at: 0)
        history = normalized(history)
        if history.count == 200 && !previousEpisodes.isEmpty {
            let retained = Set(history.map(\.id))
            previousEpisodes = previousEpisodes.filter { retained.contains($0.key) }
        }
        if let index = favorites.firstIndex(where: { $0.id == drama.id }) { favorites[index] = entry }
        needsSave = true
        if Date().timeIntervalSince(lastWrite) >= 2 { save() }
    }

    func progress(for dramaID: String) -> LibraryEntry? {
        history.first { $0.id == dramaID } ?? favorites.first { $0.id == dramaID }
    }

    func position(for dramaID: String, episodeID: String) -> Double? {
        if let entry = history.first(where: { $0.id == dramaID && $0.episodeID == episodeID }) { return entry.position }
        if let position = previousEpisodes[dramaID]?.first(where: { $0.id == episodeID })?.position { return position }
        return favorites.first { $0.id == dramaID && $0.episodeID == episodeID }?.position
    }

    func updateDramaMetadata(_ metadata: Drama) {
        guard !storageLocked else { return }
        var changed = false
        if let index = favorites.firstIndex(where: { $0.id == metadata.id }) {
            let drama = favorites[index].drama.replacingMetadata(with: metadata)
            if drama != favorites[index].drama { favorites[index].drama = drama; changed = true }
        }
        if let index = history.firstIndex(where: { $0.id == metadata.id }) {
            let drama = history[index].drama.replacingMetadata(with: metadata)
            if drama != history[index].drama { history[index].drama = drama; changed = true }
        }
        if changed { save() }
    }
    func updatePosition(dramaID: String, episodeID: String, position: Double) {
        guard !storageLocked else { return }
        guard position.isFinite, position >= 0 else { return }
        if let index = history.firstIndex(where: { $0.id == dramaID && $0.episodeID == episodeID }) {
            history[index].position = position
            needsSave = true
        }
        if let index = favorites.firstIndex(where: { $0.id == dramaID && $0.episodeID == episodeID }) {
            favorites[index].position = position
            needsSave = true
        }
        if Date().timeIntervalSince(lastWrite) >= 2 { save() }
    }
    func removeHistory(id: String) { guard !storageLocked else { return }; history.removeAll { $0.id == id }; previousEpisodes.removeValue(forKey: id); save() }
    func removeFavorite(id: String) { guard !storageLocked else { return }; favorites.removeAll { $0.id == id }; save() }
    func clearHistory() { guard !storageLocked else { return }; history.removeAll(); previousEpisodes.removeAll(); save() }
    func clearFavorites() { guard !storageLocked else { return }; favorites.removeAll(); save() }
    func flush() { save() }

    private func normalized(_ values: [LibraryEntry]) -> [LibraryEntry] {
        var seen = Set<String>()
        return Array(values.sorted { $0.updatedAt > $1.updatedAt }.filter {
            !$0.id.isEmpty && $0.id.count <= 128 && $0.position.isFinite && $0.position >= 0 && seen.insert($0.id).inserted
        }.prefix(200))
    }

    private func save() {
        guard !storageLocked else { return }
        do {
            let data = try JSONEncoder().encode(Snapshot(favorites: favorites, history: history, previousEpisodes: previousEpisodes))
            try data.write(to: fileURL, options: .atomic)
            lastWrite = Date()
            needsSave = false
            storageError = nil
        } catch {
            needsSave = true
            storageError = "本机记录暂未保存，请检查剩余存储空间。"
        }
    }
}
