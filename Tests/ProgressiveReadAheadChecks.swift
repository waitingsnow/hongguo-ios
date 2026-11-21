// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private actor CountingServer {
    let data: Data
    var requests: [Range<Int>] = []
    init(_ data: Data) { self.data = data }
    func fetch(_ range: Range<Int>) async throws -> MediaRangeReply {
        requests.append(range)
        try await Task.sleep(nanoseconds: 15_000_000)
        return MediaRangeReply(data: data.subdata(in: range.lowerBound..<min(range.upperBound, data.count)), total: data.count)
    }
    func requested() -> [Range<Int>] { requests }
}

private actor TransportLog {
    var calls: [(String, Bool)] = []
    var renewals = 0
    func add(_ url: URL, _ redirected: Bool) { calls.append((url.absoluteString, redirected)) }
    func renewed() { renewals += 1 }
}

private func expect(_ condition: Bool, _ label: String) throws {
    if !condition { throw NSError(domain: "ProgressiveReadAhead", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}

func progressiveReadAheadChecks(fixture: ProgressiveFixture, track: VideoTrack, root: URL) async throws {
    let size = ProgressiveCache.blockSize
    try expect(fixture.encrypted.count > 4 * size, "Fixture is too small for read-ahead checks")
    let server = CountingServer(fixture.encrypted)
    let source = try await ProgressiveSource.open(track: track, episodeID: "ahead", cache: ProgressiveCache(root: root.appendingPathComponent("ahead")),
                                                  fetch: { try await server.fetch($0) }, readAhead: 3 * size)
    let opening = await server.requested().count
    let first = fixture.offsets[0]
    // The window grows as playback reads in order: one block ahead at first, then several in one range.
    var block = first / size
    _ = try await source.read(at: first, count: 64)
    for _ in 0..<2 { block += 1; _ = try await source.read(at: block * size + 5, count: 64) }
    var settled = await server.requested()
    for _ in 0..<200 where !settled.dropFirst(opening).contains(where: { $0.count > size }) {
        try await Task.sleep(nanoseconds: 10_000_000); settled = await server.requested()
    }
    try expect(settled.dropFirst(opening).contains { $0.count > size }, "Read-ahead did not fetch neighbouring blocks in one range")
    try await Task.sleep(nanoseconds: 100_000_000)
    let before = await server.requested().count
    let ahead = (block + 2) * size + 11
    let bytes = try await source.read(at: ahead, count: 1_000)
    try expect(bytes == fixture.clear.subdata(in: ahead..<(ahead + 1_000)), "Read-ahead block returned wrong bytes")
    try expect(await server.requested().count <= before + 1, "A read inside the read-ahead window waited for a new request")
    await source.close()
    print("PASS read-ahead downloads neighbouring blocks in combined ranges and serves later reads from them")

    let warmServer = CountingServer(fixture.encrypted)
    let warmed = try await ProgressiveSource.open(track: track, episodeID: "warm", cache: ProgressiveCache(root: root.appendingPathComponent("warm")),
                                                  fetch: { try await warmServer.fetch($0) }, readAhead: 0)
    await warmed.warm(bytes: 2 * size)
    let afterWarm = await warmServer.requested().count
    _ = try await warmed.read(at: first, count: 4_096)
    try expect(await warmServer.requested().count == afterWarm, "Warmed first frame still went to the network")
    await warmed.close()
    print("PASS warming prepares the start of the picture data before a player exists")

    let expired = URL(string: "https://v1.qznovelvod.com/expired.mp4")!, fresh = URL(string: "https://v1.qznovelvod.com/fresh.mp4")!
    let edge = URL(string: "https://edge.vegslb.com/fresh.mp4")!
    let log = TransportLog()
    let transport: MediaLocator.Transport = { url, range, redirected in
        await log.add(url, redirected)
        if url == expired { throw MediaAddressRejected(status: 403) }
        return MediaRangeReply(data: Data(repeating: 1, count: range.count), total: 4096, address: edge)
    }
    let base = VideoTrack(url: expired, spadeA: "key", encrypted: true, definition: "720p")
    let locator = MediaLocator(track: base, renew: {
        await log.renewed(); try await Task.sleep(nanoseconds: 20_000_000)
        return VideoTrack(url: fresh, spadeA: "key", encrypted: true, definition: "720p")
    }, transport: transport)
    async let one = locator.fetch(0..<100)
    async let two = locator.fetch(100..<200)
    _ = try await (one, two)
    try expect(await log.renewals == 1, "Concurrent failures did not share one renewal")
    _ = try await locator.fetch(200..<300)
    let last = await log.calls.last
    try expect(last?.0 == edge.absoluteString && last?.1 == true, "Later ranges did not go straight to the redirect target")
    let other = MediaLocator(track: base, renew: { VideoTrack(url: fresh, spadeA: "other", encrypted: true, definition: "720p") }, transport: transport)
    do { _ = try await other.fetch(0..<100); try expect(false, "A renewed address with another key was used") } catch MediaError.transport { }
    print("PASS expired addresses are renewed once for concurrent ranges, refused for another key, and redirects are reused")
}
