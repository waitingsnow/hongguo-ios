// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private actor CountingServer {
    let data: Data
    var requests: [Range<Int>] = []
    private var delay: UInt64 = 15_000_000
    private var malformedNext = false
    private var active = 0
    private(set) var peak = 0
    private(set) var cancellations: [Range<Int>] = []
    init(_ data: Data) { self.data = data }
    func fetch(_ range: Range<Int>) async throws -> MediaRangeReply {
        requests.append(range)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        let malformed = malformedNext
        malformedNext = false
        do {
            try await Task.sleep(nanoseconds: delay)
        } catch is CancellationError {
            cancellations.append(range)
            throw CancellationError()
        }
        let upper = min(range.upperBound, data.count) - (malformed ? 1 : 0)
        return MediaRangeReply(data: data.subdata(in: range.lowerBound..<upper), total: data.count)
    }
    func configure(delay: UInt64 = 15_000_000, malformedNext: Bool = false) {
        self.delay = delay
        self.malformedNext = malformedNext
        peak = active
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

    try await progressiveWarmChecks(fixture: fixture, track: track, root: root)

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

private func progressiveWarmChecks(fixture: ProgressiveFixture, track: VideoTrack, root: URL) async throws {
    let size = ProgressiveCache.blockSize
    try expect(fixture.encrypted.count > 8 * size, "Fixture is too small for warm range checks")

    func open(_ name: String, server: CountingServer, readAhead: Int = 0) async throws -> ProgressiveSource {
        try await ProgressiveSource.open(track: track, episodeID: name, cache: ProgressiveCache(root: root.appendingPathComponent(name)),
                                         fetch: { try await server.fetch($0) }, readAhead: readAhead)
    }

    let server = CountingServer(fixture.encrypted)
    let source = try await open("warm", server: server)
    let opening = await server.requested().count
    await server.configure()
    async let wide = source.warm(bytes: 8 * size)
    async let narrow = source.warm(bytes: 2 * size)
    let (wideReady, narrowReady) = await (wide, narrow)
    try expect(wideReady && narrowReady, "Concurrent warm calls did not finish their prefixes")
    let ranges = Array(await server.requested().dropFirst(opening))
    try expect(await server.peak == 1, "Several speculative ranges ran simultaneously")
    try expect(ranges.count > 1 && ranges.allSatisfy { $0.count <= 4 * size } && ranges.contains { $0.count > size },
               "Warm ranges were not split into bounded multi-block runs")
    try expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "Concurrent warm calls duplicated or skipped a range")
    let afterWarm = await server.requested().count
    let first = fixture.offsets[0]
    let warmed = try await source.read(at: first, count: 4_096)
    try expect(warmed == fixture.clear.subdata(in: first..<(first + 4_096)), "Verified warm bytes did not match playback")
    try expect(await server.requested().count == afterWarm, "Warmed first frame still went to the network")
    await source.close()
    try expect(await source.warm(bytes: size) == false, "A closed source reported warm completion")
    print("PASS concurrent warm requests share bounded, merged ranges and verify the requested prefix")

    let offsetServer = CountingServer(fixture.encrypted)
    let offsetSource = try await open("warm-offset", server: offsetServer)
    let offsetOpening = await offsetServer.requested().count
    let mdat = nodes(fixture.encrypted, 0, fixture.encrypted.count).first { $0.type == "mdat" }!
    let mediaStart = mdat.start + (u32(fixture.encrypted, mdat.start) == 1 ? 16 : 8)
    let start = 3 * size + 23 - mediaStart
    let split = 4 * size + 71 - mediaStart
    let end = 6 * size - mediaStart
    try expect(await offsetSource.warm(bytes: split, from: start), "Unaligned warm interval failed")
    try expect(await offsetSource.warm(bytes: end, from: split), "Warm did not continue from the unaligned boundary")
    let offsetRanges = Array(await offsetServer.requested().dropFirst(offsetOpening))
    try expect(offsetRanges == [(3 * size)..<(5 * size), (5 * size)..<(6 * size)],
               "Unexpected warm ranges at unaligned boundaries: \(offsetRanges)")
    await offsetSource.close()
    print("PASS incremental warm skips earlier blocks and reuses unaligned boundary blocks")

    let failureServer = CountingServer(fixture.encrypted)
    let retry = try await open("warm-retry", server: failureServer)
    let beforeFailure = await retry.metrics()
    let requestsBeforeFailure = await failureServer.requested().count
    await failureServer.configure(malformedNext: true)
    try expect(await retry.warm(bytes: 2 * size) == false, "A short response was reported ready")
    try expect(await retry.metrics().availableBytes == beforeFailure.availableBytes, "A failed warm made blocks available")
    try expect(await retry.warm(bytes: 2 * size), "A failed warm range could not be retried")
    let retried = Array(await failureServer.requested().dropFirst(requestsBeforeFailure))
    try expect(retried.count == 2 && retried[0] == retried[1], "Retry did not fetch the failed range again")
    await retry.close()
    print("PASS malformed warm response returns false and playback can retry it")

    let soloServer = CountingServer(fixture.encrypted)
    let solo = try await open("warm-cancel", server: soloServer)
    let soloOpening = await soloServer.requested().count
    await soloServer.configure(delay: 2_000_000_000)
    let speculative = Task { await solo.warm(bytes: 8 * size) }
    try await waitForRequests(soloOpening + 1, on: soloServer)
    let cancelledAt = Date()
    speculative.cancel()
    try expect(await speculative.value == false, "Cancelled warm call reported completion")
    for _ in 0..<200 {
        if await !soloServer.cancellations.isEmpty { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let cancelled = await soloServer.cancellations
    try expect(cancelled.count == 1 && Date().timeIntervalSince(cancelledAt) < 1, "An unshared warm range did not cancel promptly")
    try expect(await soloServer.requested().count == soloOpening + 1, "Cancellation launched another warm range")
    await soloServer.configure()
    try expect(await solo.warm(bytes: 2 * size), "An unshared cancellation prevented a subsequent warm")
    await solo.close()
    print("PASS cancelling an unshared warm stops its range and starts no further ranges")

    let sharedServer = CountingServer(fixture.encrypted)
    let shared = try await open("warm-shared", server: sharedServer, readAhead: size)
    let sharedOpening = await sharedServer.requested().count
    await sharedServer.configure(delay: 1_500_000_000)
    let warming = Task { await shared.warm(bytes: 8 * size) }
    try await waitForRequests(sharedOpening + 1, on: sharedServer)
    let sharedRange = await sharedServer.requested()[sharedOpening]
    let offset = sharedRange.upperBound - 128
    let reading = Task { try await shared.read(at: offset, count: 64) }
    // The front read starts its normal lookahead just outside the shared range.
    try await waitForRequests(sharedOpening + 2, on: sharedServer)
    let detachedAt = Date()
    warming.cancel()
    try expect(await warming.value == false, "A cancelled shared warm reported completion")
    try expect(Date().timeIntervalSince(detachedAt) < 1, "Cancelled warm waited for the foreground range to finish")
    let data = try await reading.value
    try expect(data == fixture.clear.subdata(in: offset..<(offset + 64)), "Foreground read could not finish the shared range")
    let reread = try await shared.read(at: offset, count: 64)
    try expect(reread == data, "Completed shared range was not reusable")
    let sharedRequests = Array(await sharedServer.requested().dropFirst(sharedOpening))
    try expect(await sharedServer.cancellations.isEmpty, "A foreground consumer's shared range was cancelled")
    try expect(sharedRequests.filter { $0.contains(offset) } == [sharedRange], "Foreground read requested the same bytes again")
    await shared.close()
    print("PASS foreground reads retain and reuse the same warm range after its caller cancels")
}

private func waitForRequests(_ count: Int, on server: CountingServer) async throws {
    for _ in 0..<200 {
        if await server.requested().count >= count { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try expect(false, "Timed out waiting for \(count) requests")
}
