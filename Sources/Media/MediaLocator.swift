// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Where one track's bytes come from.
/// - Ranges go straight to the CDN address the last reply was redirected to, skipping the scheduling hop.
/// - When that fails, the track's own address is tried again with retries.
/// - When that fails too, or answers 4xx (signed addresses expire, which made the next episode fail with
///   "视频下载失败" even after retrying), a freshly signed address is requested through `renew`. It is used only for
///   the same encryption key, so bytes from both addresses belong to the same file.
actor MediaLocator {
    typealias Renew = @Sendable () async throws -> VideoTrack
    /// One range from an address; `redirected` marks a CDN address taken from an earlier reply.
    typealias Transport = @Sendable (_ url: URL, _ range: Range<Int>, _ redirected: Bool) async throws -> MediaRangeReply
    static let network: Transport = { url, range, redirected in
        redirected ? try await MediaRangeHTTP.fetch(redirected: url, range: range) : try await MediaRangeHTTP.fetchRetrying(url, range: range, attempts: 3)
    }
    private let track: VideoTrack
    private let renew: Renew?
    private let transport: Transport
    private var address: URL
    private var shortcut: URL?
    private var renewal: Task<URL, Error>?
    private var renewals = 0
    private static let maximumRenewals = 3

    init(track: VideoTrack, renew: Renew?, transport: @escaping Transport = MediaLocator.network) {
        self.track = track; self.renew = renew; self.transport = transport; address = track.url
    }

    func fetch(_ range: Range<Int>) async throws -> MediaRangeReply {
        if let direct = shortcut {
            do { return try await transport(direct, range, true) }
            catch is CancellationError { throw CancellationError() }
            catch { if shortcut == direct { shortcut = nil } }
        }
        let current = address
        do { return remember(try await transport(current, range, false), from: current) }
        catch is CancellationError { throw CancellationError() }
        catch { guard renew != nil else { throw Self.mapped(error) } }
        let fresh: URL
        do { fresh = try await renewed(after: current) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MediaError.transport }
        do { return remember(try await transport(fresh, range, false), from: fresh) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.mapped(error) }
    }

    private func remember(_ reply: MediaRangeReply, from origin: URL) -> MediaRangeReply {
        if origin == address, let target = reply.address, target != origin, MediaRangeHTTP.allowedAfterRedirect(target) { shortcut = target }
        return reply
    }

    /// Concurrent failures share one renewal; a caller that failed on an address already replaced just uses the new one.
    private func renewed(after failed: URL) async throws -> URL {
        if address != failed { return address }
        if let renewal { return try await renewal.value }
        guard let renew, renewals < Self.maximumRenewals else { throw MediaError.transport }
        renewals += 1
        let expected = track
        let task = Task { () throws -> URL in
            let fresh = try await renew()
            guard fresh.spadeA == expected.spadeA, fresh.encrypted == expected.encrypted, MediaRangeHTTP.allowed(fresh.url) else { throw MediaError.transport }
            return fresh.url
        }
        renewal = task
        defer { renewal = nil }
        let url = try await task.value
        address = url; shortcut = nil
        return url
    }

    private static func mapped(_ error: Error) -> Error { (error as? MediaError) ?? MediaError.transport }
}
