import Foundation
import AVFoundation

/// Opens one episode as a progressive stream: a signed address in the chosen 清晰度, renewed with the same quality when
/// it stops answering, and optionally the first part of the picture data downloaded before a player exists.
@MainActor
enum EpisodeStream {
    /// About the first two seconds of a typical episode, enough for the first frame without waiting.
    static let startBytes = 1_536 * 1024

    static func open(episodeID: String, seriesID: String, quality: VideoQuality,
                     progress: @escaping ProgressiveSource.Progress = { _, _ in }) async throws -> ProgressivePlayback {
        let track = try await DramaAPI.shared.track(episodeID: episodeID, seriesID: seriesID, quality: quality)
        try Task.checkCancellation()
        return try await ProgressivePlayback.open(track: track, episodeID: episodeID, renew: {
            try await DramaAPI.shared.track(episodeID: episodeID, seriesID: seriesID, quality: quality)
        }, progress: progress)
    }

}
