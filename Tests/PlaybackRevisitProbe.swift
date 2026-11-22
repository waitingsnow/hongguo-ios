import AVFoundation
import Foundation
@testable import Hongguo

@main @MainActor
struct PlaybackRevisitProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(description: message)
    }

    static func main() async throws {
        let media = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root.appendingPathComponent("library"))
        let cache = ProgressiveCache(root: root.appendingPathComponent("media"))
        let drama = Drama(id: UUID().uuidString, title: "First", coverURL: "", summary: "", episodeCount: 3)
        let other = Drama(id: UUID().uuidString, title: "Other", coverURL: "", summary: "", episodeCount: 1)
        let episodes = (1...3).map { Episode(id: "fixture-\($0)", index: $0, title: "Episode \($0)") }
        let detail = DramaDetail(drama: drama, episodes: episodes)
        let otherDetail = DramaDetail(drama: other, episodes: [episodes[0]])
        var firstOpenCount = 0
        var skippedOpens = 0
        let skipped = (1...5).map { Drama(id: "skipped-\($0)", title: "Skipped", coverURL: "", summary: "", episodeCount: 1) }
        let lookahead = PlaybackLookahead { target in
            if skipped.contains(where: { $0.id == target.drama.id }) { skippedOpens += 1 }
            if target.drama.id == drama.id && target.index == 0 { firstOpenCount += 1 }
            let selected = target.drama.id == drama.id ? detail : otherDetail
            let track = VideoTrack(url: URL(string: "https://test.qznovelvod.com/fixture.mp4")!, spadeA: "", encrypted: false, definition: "720p")
            let source = try await ProgressiveSource.open(track: track, episodeID: selected.drama.id + "-\(target.index)", cache: cache, fetch: { range in
                let end = min(range.upperBound, media.count)
                guard range.lowerBound < end else { throw Failure(description: "Out-of-bounds range") }
                return MediaRangeReply(data: media.subdata(in: range.lowerBound..<end), total: media.count)
            })
            return await OpenEpisode(detail: selected, stream: ProgressivePlayback.make(source: source))
        }

        let preview = FeedPreview(lookahead: lookahead, library: library)
        preview.play(drama, quality: .p720, speed: 1.5, following: [other])
        try await eventually("First preview never started") { preview.position > 0.2 }
        guard let first = preview.player else { throw Failure(description: "Missing preview player") }
        preview.markRendered(first)
        await first.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually("Preview seek never settled") { preview.position >= 4 }
        preview.setScrolling(true)
        for target in skipped { preview.select(target, quality: .p720, speed: 1.5, following: [], debounce: false) }
        try await Task.sleep(for: .milliseconds(180))
        try require(skippedOpens == 0 && preview.player === first && first.isMuted, "Fling opened an intermediate page or kept playing its audio")
        preview.setScrolling(false)
        preview.select(drama, quality: .p720, speed: 1.5, following: [], debounce: false)
        try require(preview.player === first && !first.isMuted, "Cancelled drag did not reuse the unmuted player")
        for target in skipped { preview.select(target, quality: .p720, speed: 1.5, following: [], debounce: true) }
        preview.select(other, quality: .p720, speed: 1.5, following: [], debounce: true)
        try await eventually("Other drama picked up the first drama's position") { preview.position > 0.1 && preview.position < 2 }
        try require(preview.dramaID == other.id && skippedOpens == 0, "Debounced scrolling opened an intermediate target")
        guard let otherPlayer = preview.player else { throw Failure(description: "Missing other player") }
        preview.markRendered(otherPlayer)
        preview.play(drama, quality: .p720, speed: 1.5, following: [])
        try await eventually("Returning to the first preview lost its position") { preview.position > 3.5 && preview.player?.rate == 1.5 }
        try require(firstOpenCount == 1, "Revisit reopened the previous drama's video source")
        let returned = preview.player
        let position = preview.position
        guard let request = preview.handoff(index: 0) else { throw Failure(description: "Missing live handoff after resume") }
        try require(library.history.isEmpty, "Passive previews invented local watch history")
        let app = AppModel()
        app.quality = .p720
        app.speed = 1.5
        app.autoNext = false
        defer { app.library.removeHistory(id: drama.id) }
        let session = PlayerSession(request: request, app: app)
        session.start()
        defer { session.stop() }
        try require(session.player === returned && (session.player?.currentTime().seconds ?? 0) >= position - 0.1,
                    "Live handoff reopened the player or lost the resumed position")
        try await eventually("Episode 1 never became ready") { session.rendered }
        session.go(to: 1)
        try await eventually("Unwatched episode did not start at zero") { session.index == 1 && session.rendered && session.position < 2 }
        guard let player = session.player else { throw Failure(description: "Missing full player") }
        await player.seek(to: CMTime(seconds: 7, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await eventually("Episode 2 seek never settled") { session.position >= 7 }
        session.load(index: 0)
        try await eventually("Swipe path did not restore episode 1") { session.index == 0 && session.rendered && player.currentTime().seconds > 3.5 }
        try require(firstOpenCount == 1, "Switching back reopened episode one's video source")
        session.load(index: 1)
        try await eventually("Swipe path did not restore episode 2") { session.index == 1 && session.rendered && player.currentTime().seconds > 6.5 }
        preview.play(other, quality: .p720, speed: 1, following: [])
        preview.select(skipped[0], quality: .p720, speed: 1, following: [], debounce: true)
        preview.stop()
        try await Task.sleep(for: .milliseconds(200))
        try require(skippedOpens == 0 && preview.player == nil, "A delayed preview opened after leaving the feed")
        print("PASS: 5 intermediate targets opened 0 streams in both fling modes; cancelled swipe preserved player and sound; exit cancelled pending playback; A/B/A revisit and live handoff restored positions")
    }
}
