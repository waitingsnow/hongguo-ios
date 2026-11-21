import Foundation
import AVFoundation

/// Opens one episode as a progressive stream: a signed address in the chosen 清晰度, renewed with the same quality when
/// it stops answering, and optionally the first part of the picture data downloaded before a player exists.
@MainActor
enum EpisodeStream {
    /// About the first two seconds of a typical episode, enough for the first frame without waiting.
    static let startBytes = 1_536 * 1024
    private static let wholeStep = 2 * 1024 * 1024

    static func open(episodeID: String, quality: VideoQuality,
                     progress: @escaping ProgressiveSource.Progress = { _, _ in }) async throws -> ProgressivePlayback {
        let track = try await DramaAPI.shared.track(episodeID: episodeID, quality: quality)
        try Task.checkCancellation()
        return try await ProgressivePlayback.open(track: track, episodeID: episodeID, renew: {
            try await DramaAPI.shared.track(episodeID: episodeID, quality: quality)
        }, progress: progress)
    }

    /// Downloads the start of the picture, or the whole episode in steps, and lets AVFoundation read the index, so
    /// the item becomes ready almost at once when it is played.
    static func warm(_ stream: ProgressivePlayback, whole: Bool) async {
        let source = stream.source
        let length = await source.metrics().length
        var target = startBytes
        while !Task.isCancelled {
            await source.warm(bytes: target)
            guard whole, target < length else { break }
            target = min(length, target + wholeStep)
        }
        guard !Task.isCancelled else { return }
        _ = try? await stream.asset.load(.duration, .tracks)
    }
}

/// The next episode, opened and partly downloaded while the current one plays.
struct PreparedEpisode {
    let episodeID: String
    let quality: VideoQuality
    let stream: ProgressivePlayback
}
