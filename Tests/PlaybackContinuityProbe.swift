import AVFoundation
import Foundation
import os
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

    static func seekNearEnd(_ player: AVPlayer) async throws {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 1 else {
            throw Failure(message: "no playable item duration")
        }
        let finish = CMTime(seconds: duration - 0.65, preferredTimescale: 600)
        await player.seek(to: finish, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func verifyNativeAdvance(_ session: PlayerSession, player: AVQueuePlayer, expectedRate: Float,
                                    successor: AVPlayerItem?,
                                    checkDelayedAdvance: Bool = false,
                                    opened: () -> Int?) async throws {
        try await eventually("active series never queued the next episode with native advance enabled") {
            player.items().count == (successor == nil ? 2 : 3) && player.actionAtItemEnd == .advance
        }
        let before = player.items()
        let previous = session.episode
        let nextIndex = session.index + 1
        let staged = before[1]
        if let successor {
            try require(before[2] === successor, "second successor was not in the queue before the boundary")
        }
        staged.preferredForwardBufferDuration = 3
        let openCount = opened()
        if checkDelayedAdvance {
            guard let current = player.currentItem else { throw Failure(message: "no current item before delayed advance") }
            let ticket = session.playID
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: current)
            try await Task.sleep(for: .milliseconds(500))
            try require(session.playID == ticket && player.currentItem === current
                        && player.items().map(ObjectIdentifier.init) == before.map(ObjectIdentifier.init)
                        && player.actionAtItemEnd == .advance && player.rate == expectedRate && opened() == openCount,
                        "an early end notification interrupted a healthy queue")
            print("PASS: a healthy staged item survived 500 ms after an early end notification")
        }
        var transitions = 0
        var savedCompletion = false
        var adoptedWithExpectedQueue = false
        let episodeChange = session.$playID.dropFirst().sink { _ in
            transitions += 1
            let saved = session.app.library.progress(for: session.detail.drama.id)
            savedCompletion = saved?.episodeID == previous.id && saved?.position == 0
            let items = player.items()
            if let successor {
                adoptedWithExpectedQueue = items.count == 2 && items[1] === successor && player.actionAtItemEnd == .advance
            } else {
                adoptedWithExpectedQueue = items.count == 1 && player.actionAtItemEnd == .pause
            }
        }
        defer { episodeChange.cancel() }
        try await seekNearEnd(player)
        try await eventually("seek did not return to the requested rate") {
            player.timeControlStatus == .playing && player.rate == expectedRate
        }
        let pauses = OSAllocatedUnfairLock(initialState: 0)
        let status = player.observe(\.timeControlStatus, options: [.new]) { @Sendable player, change in
            if (change.newValue ?? player.timeControlStatus) == .paused { pauses.withLock { $0 += 1 } }
        }
        let rate = player.observe(\.rate, options: [.new]) { @Sendable _, change in
            if change.newValue == 0 { pauses.withLock { $0 += 1 } }
        }
        defer { status.invalidate(); rate.invalidate() }
        try await eventually("series did not advance on its own") {
            session.index == nextIndex && player.currentItem === staged && player.currentTime().seconds > 0.35 && session.rendered
        }
        try require(pauses.withLock { $0 } == 0, "native transition paused playback")
        try require(player.rate == expectedRate && session.isPlaying, "native transition lost playback speed")
        try require(staged.preferredForwardBufferDuration == 3, "native transition rewrote the promoted item's buffer duration")
        try require(transitions == 1 && opened() == openCount, "native transition duplicated a switch or reopened an item")
        try require(adoptedWithExpectedQueue, "native handoff did not immediately publish the expected successor and end action")
        try require(savedCompletion, "native transition did not settle the previous episode's progress")
        try require(session.app.library.progress(for: session.detail.drama.id)?.episodeID == session.episode.id,
                    "native transition did not record the new episode")
        print("PASS: episode \(previous.index) → \(session.episode.index), \(expectedRate)×, no pause or reopen")
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
        var failNextOpen: Int?
        let queue = PlaybackLookahead { target in
            opened[target.index, default: 0] += 1
            try await Task.sleep(for: .milliseconds(120))
            if failNextOpen == target.index {
                failNextOpen = nil
                throw Failure(message: "fixture lookahead failure")
            }
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
            return queue.preparedEpisode(for: targets[2]) != nil && PlaybackLookahead.frame(targets[3]) != nil
        }
        guard let prepared = queue.preparedEpisode(for: targets[2]) else { throw Failure(message: "missing prepared episode") }
        nativePlayer.insert(prepared.item, after: promoted.item)
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
        defer { app.library.removeHistory(id: drama.id) }
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
        try await eventually("both successors were not preheated before the native handoff") {
            nextSession.isPlaying && seriesPlayer.items().count == 3 && seriesPlayer.actionAtItemEnd == .advance
        }
        let pausedQueue = seriesPlayer.items().map(ObjectIdentifier.init)
        nextSession.toggle()
        try require(pauseEvents == 1 && !nextSession.isPlaying && seriesPlayer.actionAtItemEnd == .pause,
                    "explicit foreground pause must reveal the controls and disarm the queue")
        nextSession.toggle()
        try await eventually("second episode did not resume with its original queue") {
            nextSession.isPlaying && seriesPlayer.actionAtItemEnd == .advance
                && seriesPlayer.items().map(ObjectIdentifier.init) == pausedQueue
        }
        guard let successor = queue.preparedEpisode(for: targets[3]) else { throw Failure(message: "missing preheated successor") }
        nextSession.lockSpeed()
        try require(nextSession.speedLocked, "could not lock 2× before the native transitions")
        let endActions = OSAllocatedUnfairLock(initialState: [AVPlayer.ActionAtItemEnd]())
        let endActionObservation = seriesPlayer.observe(\.actionAtItemEnd, options: [.new]) { @Sendable player, change in
            let action = change.newValue ?? player.actionAtItemEnd
            endActions.withLock { $0.append(action) }
        }
        defer { endActionObservation.invalidate() }
        try await verifyNativeAdvance(nextSession, player: seriesPlayer, expectedRate: 2, successor: successor.item,
                                      checkDelayedAdvance: true) { opened[2] }
        try require(endActions.withLock { $0.isEmpty }, "end action changed on the way to the second native advance")
        try await verifyNativeAdvance(nextSession, player: seriesPlayer, expectedRate: 2, successor: nil) { opened[3] }
        try require(endActions.withLock { $0 } == [.pause], "end action must change exactly once, on entry to the last episode")
        endActionObservation.invalidate()
        print("PASS: both successors queued before the boundary, continuous .advance at 2× and buffer settings retained")
        try require(nextSession.speedLocked && pauseEvents == 1, "autoplay changed the speed lock or reported a user pause")
        let lastTicket = nextSession.playID
        let lastItem = seriesPlayer.currentItem
        try require(seriesPlayer.actionAtItemEnd == .pause, "last episode did not retain its end action")
        try await seekNearEnd(seriesPlayer)
        try await eventually("last episode did not finish") { nextSession.endMessage == "已播完最后一集" }
        try require(seriesPlayer.rate == 0 && seriesPlayer.currentItem === lastItem && nextSession.playID == lastTicket
                    && app.library.progress(for: drama.id)?.position == 0, "last episode changed items, kept playing, or left stale progress")
        nextSession.suspend()
        try require(!nextSession.isPlaying && pauseEvents == 1, "background suspension must not reveal the controls")
        nextSession.stop()

        let fallbackRequest = PlaybackRequest(detail: detail, index: 0, position: 0, recordsLocalHistory: false,
                                              handoff: FeedHandoff(lookahead: queue, live: nil, speedLocked: false))
        let fallback = PlayerSession(request: fallbackRequest, app: app)
        let nextOpenCount = opened[1, default: 0]
        failNextOpen = 1
        fallback.start()
        try await eventually("distant candidate did not prepare after the immediate candidate failed") {
            fallback.rendered && failNextOpen == nil && queue.preparedEpisode(for: targets[2]) != nil
        }
        guard let fallbackPlayer = fallback.player as? AVQueuePlayer,
              let first = fallbackPlayer.currentItem else { throw Failure(message: "no fallback player") }
        try require(fallbackPlayer.items().count == 1 && fallbackPlayer.actionAtItemEnd == .pause,
                    "failed preloading armed an unavailable next item or staged a nonconsecutive episode")
        try await seekNearEnd(fallbackPlayer)
        try await eventually("failed lookahead did not fall back to opening the next episode") {
            fallback.index == 1 && fallbackPlayer.currentItem !== first && fallbackPlayer.currentTime().seconds > 0.15
        }
        try require(opened[1] == nextOpenCount + 2, "fallback did not open the next item exactly once after its preload failed")
        try await eventually("fallback session did not stage its next episode") {
            fallbackPlayer.items().count == 3 && fallbackPlayer.actionAtItemEnd == .advance
        }
        let manualNext = fallbackPlayer.items()[1]
        let manualNextOpens = opened[2]
        let timerItem = fallbackPlayer.currentItem
        let timerTicket = fallback.playID
        fallback.stopAtEpisodeEnd()
        try require(fallbackPlayer.actionAtItemEnd == .pause, "end-of-episode timer left native advance armed")
        fallback.setSleepTimer(minutes: nil)
        try require(fallbackPlayer.actionAtItemEnd == .advance, "clearing the timer did not restore native advance")
        app.autoNext = false
        try require(fallbackPlayer.actionAtItemEnd == .pause, "disabling autoplay left native advance armed")
        try await seekNearEnd(fallbackPlayer)
        try await eventually("autoplay-disabled episode did not stop") { fallback.endMessage == "本集已播完，上滑观看下一集" }
        try require(fallback.index == 1 && fallbackPlayer.currentItem === timerItem && fallback.playID == timerTicket
                    && fallbackPlayer.rate == 0, "disabled autoplay switched to the staged item")
        app.autoNext = true
        fallback.go(to: 2)
        try await eventually("next episode did not start after disabled autoplay") { fallback.rendered && fallback.index == 2 }
        try require(fallbackPlayer.currentItem === manualNext && opened[2] == manualNextOpens,
                    "selecting the next item reopened it or used the old tail")
        try await eventually("timer session did not stage its next episode") {
            fallbackPlayer.items().count == 2 && fallbackPlayer.actionAtItemEnd == .advance
        }
        let stoppedItem = fallbackPlayer.currentItem
        fallback.stopAtEpisodeEnd()
        try await seekNearEnd(fallbackPlayer)
        try await eventually("end-of-episode timer did not pause") { fallback.pausedBySleepTimer }
        try require(fallback.index == 2 && fallbackPlayer.currentItem === stoppedItem && fallbackPlayer.rate == 0,
                    "end-of-episode timer advanced to a queued episode")
        fallback.stop()

        let manual = PlayerSession(request: fallbackRequest, app: app)
        manual.start()
        try await eventually("manual session never queued two successors") {
            (manual.player as? AVQueuePlayer)?.items().count == 3
        }
        guard let manualPlayer = manual.player as? AVQueuePlayer else { throw Failure(message: "missing manual queue") }
        let originalItems = manualPlayer.items()
        let secondNextOpens = opened[2]
        manual.go(to: 2)
        try await eventually("direct selection of the second successor did not play") { manual.index == 2 && manual.rendered }
        try require(manualPlayer.currentItem === originalItems[2] && opened[2] == secondNextOpens,
                    "direct selection reopened or skipped the prepared item")
        try require(!manualPlayer.items().contains { $0 === originalItems[1] },
                    "the stale predecessor remained in the queue after direct selection")
        try await eventually("manual session did not queue the final episode") { manualPlayer.items().count == 2 }
        manual.setSleepTimer(minutes: 0)
        try require(manual.pausedBySleepTimer && manualPlayer.rate == 0 && manualPlayer.items().count == 1
                    && manualPlayer.actionAtItemEnd == .pause, "immediate timer left pending playback")
        manual.stop()
        try require(manualPlayer.items().isEmpty, "stopping the session left items attached")
        print("PASS: bounded lookahead, live handoff, manual selection, failed-preload fallback, last episode, disabled autoplay and timers")
    }
}
