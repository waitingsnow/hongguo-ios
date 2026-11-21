import AVFoundation
import Foundation
@testable import Hongguo

@main @MainActor
struct PlaybackContinuityProbe {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: message)
    }

    static func main() async throws {
        let media = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProgressiveCache(root: directory)
        let drama = Drama(id: UUID().uuidString, title: "测试剧", coverURL: "", summary: "", episodeCount: 4)
        let episodes = (1...4).map { Episode(id: "fixture-\($0)", index: $0, title: "第 \($0) 集") }
        let detail = DramaDetail(drama: drama, episodes: episodes)
        let targets = episodes.indices.map { PlaybackTarget(detail, index: $0, quality: .p720) }
        var opened: [Int: Int] = [:]
        let queue = PlaybackLookahead { target in
            opened[target.index, default: 0] += 1
            try await Task.sleep(for: .milliseconds(120))
            let track = VideoTrack(url: URL(string: "https://test.qznovelvod.com/fixture.mp4")!, spadeA: "", encrypted: false, definition: "720p")
            let source = try await ProgressiveSource.open(track: track, episodeID: episodes[target.index].id, cache: cache, fetch: { range in
                let end = min(range.upperBound, media.count)
                guard range.lowerBound < end else { throw Failure(message: "out-of-bounds request") }
                return MediaRangeReply(data: media.subdata(in: range.lowerBound..<end), total: media.count)
            })
            return await OpenEpisode(detail: detail, stream: ProgressivePlayback.make(source: source))
        }
        queue.update(Array(targets[1...2]), depth: 0)
        try require(opened.isEmpty, "starved playback scheduled speculative work")
        queue.update(Array(targets[1...2]), depth: 1)
        try await eventually("first candidate was not started") { opened[1] == 1 }
        let promoted = try await queue.claim(targets[1]).value
        try require(opened == [1: 1], "promotion duplicated a request or opened the distant candidate")
        let nativePlayer = AVQueuePlayer(items: [promoted.item])
        nativePlayer.actionAtItemEnd = .pause
        try await eventually("lookahead did not prepare both frames") {
            queue.update(Array(targets[2...3]), depth: 3)
            queue.stageNext(targets[2], on: nativePlayer)
            return PlaybackLookahead.frame(targets[3]) != nil && nativePlayer.items().count == 2
        }
        let next = try await queue.claim(targets[2]).value
        try require(nativePlayer.items()[1] === next.item, "native player staged the wrong item")
        nativePlayer.advanceToNextItem()
        try require(nativePlayer.currentItem === next.item && opened[2] == 1 && opened[3] == 1, "next episode was reopened")
        nativePlayer.removeAllItems()
        queue.clear()

        let feed = FeedPreview(lookahead: queue)
        feed.play(drama, quality: .p720, speed: 1.5, following: [])
        try await eventually("preview did not play at the default rate") {
            feed.player?.rate == 1.5 && feed.position > 0.15
        }
        guard let player = feed.player, let item = player.currentItem else { throw Failure(message: "no preview player") }
        feed.markRendered(player)
        feed.beginHold()
        try require(player.rate == 2, "preview hold did not accelerate")
        feed.endHold()
        try require(player.rate == 1.5, "preview hold did not restore the default")
        feed.toggle(); feed.toggle()
        try await eventually("resumed preview lost its speed") { player.rate == 1.5 }
        let position = feed.position
        guard let request = feed.handoff(index: 0) else { throw Failure(message: "missing handoff") }
        feed.stop()
        let app = AppModel()
        app.quality = .p720; app.speed = 1.5; app.autoNext = true
        let session = PlayerSession(request: request, app: app)
        session.start()
        try require(session.player === player && player.currentItem === item && player.currentTime().seconds >= position - 0.05, "handoff replaced the live player, item or position")
        try require(opened[0] == 1, "handoff reopened the first episode")
        session.stop()

        let nextFeed = FeedPreview(lookahead: queue)
        nextFeed.play(drama, quality: .p720, speed: 1.5, following: [])
        try await eventually("second preview did not start") { nextFeed.position > 0.1 }
        guard let previewPlayer = nextFeed.player else { throw Failure(message: "no second preview player") }
        nextFeed.markRendered(previewPlayer)
        try await eventually("active playback never prepared the continuation") { PlaybackLookahead.frame(targets[1]) != nil }
        nextFeed.beginHold()
        nextFeed.lockSpeed()
        nextFeed.endHold()
        try require(previewPlayer.rate == 2 && nextFeed.speedLocked, "releasing the hold lost the lock")
        let finish = CMTime(seconds: previewPlayer.currentItem!.duration.seconds - 0.25, preferredTimescale: 600)
        await previewPlayer.seek(to: finish, toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually("preview never reported the end") { nextFeed.ended }
        let count = opened[1]
        guard let continuation = nextFeed.handoff(index: 1) else { throw Failure(message: "missing autoplay handoff") }
        let nextSession = PlayerSession(request: continuation, app: app)
        nextSession.start()
        try await eventually("continuation did not play") { nextSession.player?.currentTime().seconds ?? 0 > 0.1 }
        try require(nextSession.index == 1 && opened[1] == count && nextSession.player?.rate == 2, "autoplay lost the prepared episode or locked speed")
        nextSession.unlockSpeed()
        try require(nextSession.player?.rate == 1.5 && app.speed == 1.5, "unlock changed the user's default")
        nextSession.firstFrame(ticket: nextSession.playID)
        guard let seriesPlayer = nextSession.player as? AVQueuePlayer else { throw Failure(message: "missing series queue") }
        var pauseEvents = 0
        let pauseObservation = nextSession.didPausePlayback.sink { pauseEvents += 1 }
        defer { pauseObservation.cancel() }
        try await eventually("second episode never reported playback") { nextSession.isPlaying }
        nextSession.toggle()
        try require(pauseEvents == 1 && !nextSession.isPlaying, "explicit foreground pause must reveal the controls")
        nextSession.toggle()
        try await eventually("second episode did not resume") { nextSession.isPlaying }
        nextSession.holdForGesture()
        try await eventually("gesture did not momentarily pause playback") { !nextSession.isPlaying }
        nextSession.releaseGesture()
        try await eventually("cancelled gesture did not resume playback") { nextSession.isPlaying }
        try require(pauseEvents == 1, "temporary gesture pause must not reveal the controls")

        try await eventually("active series never queued the next episode") { seriesPlayer.items().count == 2 }
        let staged = seriesPlayer.items()[1]
        let opensBeforeEnd = opened[2]
        let nearEnd = CMTime(seconds: seriesPlayer.currentItem!.duration.seconds - 0.2, preferredTimescale: 600)
        await seriesPlayer.seek(to: nearEnd, toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually("series did not advance on its own") {
            nextSession.index == 2 && seriesPlayer.currentItem === staged && seriesPlayer.currentTime().seconds > 0.05
        }
        try require(opened[2] == opensBeforeEnd, "autoplay reopened a staged series item")
        try require(pauseEvents == 1, "autoplay must not report a user-visible pause while replacing the item")
        nextSession.suspend()
        try require(!nextSession.isPlaying && pauseEvents == 1, "background suspension must not reveal the controls")
        nextSession.stop()
        print("PASS: bounded lookahead, promotion, decoded frames, native queue advance, default speed, live handoff, preloaded autoplay and playback chrome pause events")
    }
}
