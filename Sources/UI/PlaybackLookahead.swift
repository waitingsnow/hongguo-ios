import AVFoundation
import UIKit
import Nuke

struct PlaybackTarget {
    let drama: Drama
    let detail: DramaDetail?
    let index: Int
    let quality: VideoQuality

    init(_ drama: Drama, quality: VideoQuality) {
        self.drama = drama
        self.detail = nil
        self.index = 0
        self.quality = quality
    }

    init(_ detail: DramaDetail, index: Int, quality: VideoQuality) {
        self.drama = detail.drama
        self.detail = detail
        self.index = index
        self.quality = quality
    }

    var key: String { "\(drama.id)/\(index)/\(quality.rawValue)" }
}

@MainActor
final class OpenEpisode {
    let detail: DramaDetail
    let stream: ProgressivePlayback
    private(set) lazy var item = AVPlayerItem(asset: stream.asset, automaticallyLoadedAssetKeys: ["duration", "tracks"])

    init(detail: DramaDetail, stream: ProgressivePlayback) {
        self.detail = detail
        self.stream = stream
    }

    func renewItemForRevisit() {
        item = AVPlayerItem(asset: stream.asset, automaticallyLoadedAssetKeys: ["duration", "tracks"])
    }

    deinit { stream.close() }
}

@MainActor
final class PlaybackLookahead {
    private final class Slot {
        let open: Task<OpenEpisode, Error>
        var headReady = false
        var warmedBytes = 0
        var length = 0
        var preparedEpisode: OpenEpisode?
        var hasOpened = false
        init(open: Task<OpenEpisode, Error>) { self.open = open }
    }

    private static let frames: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    nonisolated private static let diskFrames: DataCache? = {
        let cache = try? DataCache(name: "hongguo.first-frames")
        cache?.sizeLimit = 24 * 1024 * 1024
        return cache
    }()
    var frameAvailable: (() -> Void)?
    private let openEpisode: @MainActor (PlaybackTarget) async throws -> OpenEpisode
    private var slots: [String: Slot] = [:]
    private var failedAt: [String: Date] = [:]
    private var worker: Task<Void, Never>?
    private var activeKey: String?
    private var generation = UUID()
    private var previous: (key: String, episode: OpenEpisode)?

    init(openEpisode: @escaping @MainActor (PlaybackTarget) async throws -> OpenEpisode = PlaybackLookahead.openEpisodeStream) {
        self.openEpisode = openEpisode
    }

    static func frame(_ target: PlaybackTarget) -> UIImage? { frames.object(forKey: target.key as NSString) }

    static func clearFrames() async {
        frames.removeAllObjects()
        await Task.detached(priority: .utility) { diskFrames?.removeAll(); diskFrames?.flush() }.value
    }

    static func diskFrameBytes() async -> Int64 {
        await Task.detached(priority: .utility) { Int64(diskFrames?.totalSize ?? 0) }.value
    }

    static func restoreFrame(_ target: PlaybackTarget) async -> Bool {
        if frame(target) != nil { return true }
        let key = target.key
        let image = await Task.detached(priority: .utility) {
            diskFrames?.cachedData(for: key).flatMap { UIImage(data: $0) }
        }.value
        guard let image, !Task.isCancelled else { return false }
        frames.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height) * 4)
        return true
    }

    static func capture(_ episode: OpenEpisode, target: PlaybackTarget) async {
        guard !(await restoreFrame(target)), !Task.isCancelled else { return }
        let generator = AVAssetImageGenerator(asset: episode.stream.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceAfter = .zero
        guard let result = try? await withTaskCancellationHandler(operation: {
            try await generator.image(at: .zero)
        }, onCancel: { generator.cancelAllCGImageGeneration() }), !Task.isCancelled else { return }
        let image = result.image
        let preview = UIImage(cgImage: image)
        let key = target.key
        frames.setObject(preview, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        await Task.detached(priority: .utility) {
            if let data = preview.jpegData(compressionQuality: 0.84) { diskFrames?.storeData(data, for: key) }
        }.value
    }

    static func depth(player: AVPlayer, speed: Float) -> Int {
        guard player.timeControlStatus == .playing, let item = player.currentItem, !item.isPlaybackBufferEmpty else { return 0 }
        let now = player.currentTime()
        let ahead = item.loadedTimeRanges.map(\.timeRangeValue).filter { CMTimeRangeContainsTime($0, time: now) }
            .map { CMTimeSubtract(CMTimeRangeGetEnd($0), now).seconds }.max() ?? 0
        let rate = Double(max(1, speed))
        if ahead >= 5 * rate { return 3 }
        if ahead >= 1.5 * rate { return 1 }
        let remaining = item.duration.seconds - now.seconds
        return remaining.isFinite && remaining > 0 && ahead >= remaining - 0.25 ? 1 : 0
    }

    private static func openEpisodeStream(_ target: PlaybackTarget) async throws -> OpenEpisode {
        let detail: DramaDetail
        if let known = target.detail { detail = known } else { detail = try await DramaDetails.load(target.drama) }
        try Task.checkCancellation()
        guard detail.episodes.indices.contains(target.index) else { throw HGError.message("这部剧暂时没有可播放剧集") }
        let stream = try await EpisodeStream.open(episodeID: detail.episodes[target.index].id, seriesID: detail.drama.id, quality: target.quality)
        return OpenEpisode(detail: detail, stream: stream)
    }

    private func open(_ target: PlaybackTarget, priority: TaskPriority) -> Task<OpenEpisode, Error> {
        Task(priority: priority) { [openEpisode] in try await openEpisode(target) }
    }

    func claim(_ target: PlaybackTarget) -> Task<OpenEpisode, Error> {
        let slot = slots.removeValue(forKey: target.key)
        pause()
        if slot == nil, let recent = previous, canRevisit(target) {
            previous = nil
            recent.episode.renewItemForRevisit()
            return Task {
                try Task.checkCancellation()
                await recent.episode.stream.source.setPaused(false)
                return recent.episode
            }
        }
        if slot?.preparedEpisode?.item.status == .failed { return open(target, priority: .userInitiated) }
        return slot?.open ?? open(target, priority: .userInitiated)
    }

    func rememberForRevisit(_ episode: OpenEpisode, target: PlaybackTarget) {
        guard episode.item.status == .readyToPlay else { return }
        previous = (target.key, episode)
    }

    func canRevisit(_ target: PlaybackTarget) -> Bool { previous?.key == target.key && previous?.episode.item.status != .failed }

    func pause() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        if let activeKey, let slot = slots[activeKey], !slot.hasOpened {
            slots.removeValue(forKey: activeKey)?.open.cancel()
        }
        activeKey = nil
    }

    func clear() {
        pause()
        previous = nil
        for slot in slots.values { slot.open.cancel() }
        slots.removeAll()
        failedAt.removeAll()
    }

    func preparedEpisode(for target: PlaybackTarget) -> OpenEpisode? {
        guard let episode = slots[target.key]?.preparedEpisode, episode.item.status != .failed else { return nil }
        return episode
    }

    func consumePrepared(_ episode: OpenEpisode, for target: PlaybackTarget) {
        guard slots[target.key]?.preparedEpisode === episode else { return }
        slots.removeValue(forKey: target.key)
    }

    func update(_ targets: [PlaybackTarget], depth: Int, wholeFirst: Bool = false) {
        let keys = Set(targets.map(\.key))
        for key in Array(slots.keys) where !keys.contains(key) { slots.removeValue(forKey: key)?.open.cancel() }
        failedAt = failedAt.filter { keys.contains($0.key) && Date().timeIntervalSince($0.value) < 15 }
        let allowed = targets.prefix(depth)
        guard !allowed.isEmpty else { if worker != nil { pause() }; return }
        let next = allowed.first { slots[$0.key]?.headReady != true && failedAt[$0.key] == nil }
        let whole = wholeFirst && depth > 1 ? targets.first.flatMap { target -> PlaybackTarget? in
            guard failedAt[target.key] == nil else { return nil }
            return slots[target.key].flatMap { $0.headReady && $0.warmedBytes < $0.length ? target : nil }
        } : nil
        guard let target = next ?? whole else { if worker != nil { pause() }; return }
        if worker != nil && activeKey == target.key { return }
        pause()
        let slot = slots[target.key] ?? Slot(open: open(target, priority: .utility))
        slots[target.key] = slot
        activeKey = target.key
        let ticket = generation
        worker = Task(priority: .utility) { [weak self] in
            do {
                let episode = try await slot.open.value
                try Task.checkCancellation()
                slot.hasOpened = true
                if !slot.headReady {
                    await Self.capture(episode, target: target)
                    try Task.checkCancellation()
                    self?.frameAvailable?()
                    _ = try await episode.stream.asset.load(.duration, .tracks)
                    slot.length = await episode.stream.source.metrics().length
                }
                let bytes = min(slot.length, slot.warmedBytes + EpisodeStream.startBytes)
                let warmed = await episode.stream.source.warm(bytes: bytes, from: slot.warmedBytes)
                try Task.checkCancellation()
                guard warmed else { throw MediaError.transport }
                slot.warmedBytes = bytes
                slot.headReady = true
                slot.preparedEpisode = episode
            } catch {
                guard let self, self.generation == ticket else { return }
                self.failedAt[target.key] = Date()
                if !slot.headReady { self.slots.removeValue(forKey: target.key) }
            }
            guard let self, self.generation == ticket else { return }
            self.worker = nil
            self.activeKey = nil
        }
    }
}
