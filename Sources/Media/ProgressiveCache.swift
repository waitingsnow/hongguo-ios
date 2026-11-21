// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// Verified, reusable encrypted ranges. A partial movie is never mistaken for a complete MP4.
actor ProgressiveCache {
    static let shared = ProgressiveCache()
    static let blockSize = 256 * 1024
    private let root: URL
    private let limit: Int
    private var leases: [String: Int] = [:]
    private let fm = FileManager.default
    /// Bytes and last use per cache folder, read from disk once and then kept up to date, so storing a block no
    /// longer walks every cached file.
    private var usage: [String: (bytes: Int, used: Date)]?

    init(root: URL? = nil, limit: Int = MP4Processor.maximumBytes) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProgressiveMedia-v1", isDirectory: true)
        self.limit = limit
    }
    func acquire(_ key: String) { leases[key, default: 0] += 1 }
    func release(_ key: String) {
        let value = leases[key, default: 0] - 1
        if value <= 0 { leases.removeValue(forKey: key) } else { leases[key] = value }
    }
    /// Block numbers present on disk for `key`, unverified until read.
    func blocks(key: String) -> Set<Int> {
        guard valid(key), let files = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(key).path) else { return [] }
        return Set(files.compactMap { $0.hasSuffix(".chunk") ? Int($0.dropLast(6)) : nil })
    }
    func read(key: String, block: Int, expected: Int) -> Data? {
        guard valid(key), block >= 0, expected > 0, expected <= Self.blockSize else { return nil }
        let folder = root.appendingPathComponent(key), file = folder.appendingPathComponent("\(block).chunk")
        guard let envelope = try? Data(contentsOf: file) else { return nil }
        guard envelope.count == expected + 32 else { discard(file, key: key, bytes: envelope.count); return nil }
        let bytes = Data(envelope.dropFirst(32))
        guard Data(SHA256.hash(data: bytes)) == envelope.prefix(32) else { discard(file, key: key, bytes: envelope.count); return nil }
        touch(folder, key: key)
        return bytes
    }
    func store(_ bytes: Data, key: String, block: Int) throws {
        guard valid(key), block >= 0, !bytes.isEmpty, bytes.count <= Self.blockSize else { throw MediaError.invalidMedia }
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(block).chunk")
        var folders = usage ?? scan()
        let existing = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
        let needed = bytes.count + 32 - existing
        var used = folders.values.reduce(0) { $0 + $1.bytes }
        if used + needed > limit {
            for (name, entry) in folders.sorted(by: { $0.value.used < $1.value.used }) where used + needed > limit {
                guard name != key, leases[name, default: 0] == 0 else { continue }
                try fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
                folders.removeValue(forKey: name); used -= entry.bytes
            }
        }
        usage = folders
        // Streaming can continue from memory when every cache directory is in use.
        guard used + needed <= limit else { return }
        try (Data(SHA256.hash(data: bytes)) + bytes).write(to: file, options: .atomic)
        let previous = folders[key]?.bytes ?? 0
        folders[key] = (previous + needed, Date())
        usage = folders
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    }
    func clear() throws {
        defer { usage = nil }
        guard fm.fileExists(atPath: root.path) else { return }
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where leases[folder.lastPathComponent, default: 0] == 0 {
            try fm.removeItem(at: folder)
        }
    }
    private func scan() -> [String: (bytes: Int, used: Date)] {
        var result: [String: (bytes: Int, used: Date)] = [:]
        let directories = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for directory in directories {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            result[directory.lastPathComponent] = (size, (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return result
    }
    private func touch(_ folder: URL, key: String) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        guard var folders = usage, let entry = folders[key] else { return }
        folders[key] = (entry.bytes, Date())
        usage = folders
    }
    private func discard(_ file: URL, key: String, bytes: Int) {
        try? fm.removeItem(at: file)
        guard var folders = usage, let entry = folders[key] else { return }
        folders[key] = (max(0, entry.bytes - bytes), entry.used)
        usage = folders
    }
    private func valid(_ key: String) -> Bool { key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}
