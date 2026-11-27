// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import os

/// A random-access clear MP4 view over verified encrypted HTTP ranges.
/// Reads keep a window ahead of the latest position downloading in runs of several blocks, so AVPlayer's sequential
/// reads are answered from memory instead of waiting for one 256 KB request at a time.
final class ProgressiveSource: Sendable {
    typealias Fetch = @Sendable (Range<Int>) async throws -> MediaRangeReply
    typealias Progress = @Sendable (String, Double) -> Void
    struct Metrics: Sendable { let length: Int; let networkBytes: Int; let availableBytes: Int }
    private struct Pending {
        let id: UUID
        let task: Task<[Data], Error>
        let position: Int
    }
    private enum WarmStep {
        case verified(Int), disk(String, Int), retry, stopped
    }
    private enum BlockStep {
        case memory(Data), disk(String, Int), loading(Pending, retry: Bool)
    }
    private struct WarmWaiter {
        let load: UUID
        let continuation: CheckedContinuation<WarmStep, Never>
        let success: WarmStep
        let failure: WarmStep
    }
    /// Bytes kept downloading ahead of the latest read during playback.
    static let defaultReadAhead = 6 * 1024 * 1024
    private static let runBlocks = 4
    private static let concurrentRuns = 2
    private static let memoryBlocks = 32
    private let fetch: Fetch
    private let cache: ProgressiveCache
    private let readAhead: Int
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var progress: Progress
        var readAheadFrom = -1
        var streakStart = -1
        var runs: [UUID: Task<[Data], Error>] = [:]
        var warmRun: (id: UUID, blocks: ClosedRange<Int>, draining: Bool)?
        var warmWaiters: [UUID: WarmWaiter] = [:]
        var warmReaders: Set<UUID> = []
        var mediaStart = 0
        var sampleBytes = 0
        var cacheKey: String?
        var plan: MP4Processor.StreamPlan?
        var memory: [Int: Data] = [:]
        var order: [Int] = []
        var pending: [Int: Pending] = [:]
        var available: Set<Int> = []
        var sampleMemory: [Int: Data] = [:]
        var sampleOrder: [Int] = []
        var paused = false
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var closed = false
        var length = 0
        var networkBytes = 0

        func known(_ index: Int) -> Bool { memory[index] != nil || pending[index] != nil || available.contains(index) }

        mutating func remember(_ data: Data, block: Int) {
            memory[block] = data; order.removeAll { $0 == block }; order.append(block)
            while order.count > ProgressiveSource.memoryBlocks { memory.removeValue(forKey: order.removeFirst()) }
        }

        func metrics() -> Metrics {
            let bytes = available.reduce(0) { $0 + min(ProgressiveCache.blockSize, length - $1 * ProgressiveCache.blockSize) }
            return Metrics(length: length, networkBytes: networkBytes, availableBytes: bytes)
        }

        mutating func takeWarmWaiters(_ load: UUID) -> [WarmWaiter] {
            warmWaiters.keys.filter { warmWaiters[$0]?.load == load }.compactMap { warmWaiters.removeValue(forKey: $0) }
        }

        mutating func drainUnusedWarmRun() -> Task<[Data], Error>? {
            guard let warmRun, !warmRun.draining, warmReaders.isEmpty,
                  !warmWaiters.values.contains(where: { $0.load == warmRun.id }) else { return nil }
            self.warmRun?.draining = true
            for index in warmRun.blocks where pending[index]?.id == warmRun.id { pending.removeValue(forKey: index) }
            return runs[warmRun.id]
        }
    }

    private init(cache: ProgressiveCache, fetch: @escaping Fetch, readAhead: Int, progress: @escaping Progress) {
        self.cache = cache; self.fetch = fetch; self.readAhead = max(0, readAhead)
        self.state = OSAllocatedUnfairLock(initialState: State(progress: progress))
    }
    /// `renew` asks the playback API for a freshly signed address of the same track when the current one stops
    /// answering (see `MediaLocator`).
    static func open(track: VideoTrack, episodeID: String, cache: ProgressiveCache = .shared,
                     fetch: Fetch? = nil, renew: MediaLocator.Renew? = nil, readAhead: Int = defaultReadAhead,
                     progress: @escaping Progress = { _, _ in }) async throws -> ProgressiveSource {
        guard !episodeID.isEmpty, episodeID.count <= 64, MediaRangeHTTP.allowed(track.url) else { throw MediaError.unavailable }
        let locator = MediaLocator(track: track, renew: renew)
        let provider: Fetch = fetch ?? { range in try await locator.fetch(range) }
        let source = ProgressiveSource(cache: cache, fetch: provider, readAhead: readAhead, progress: progress)
        return try await withTaskCancellationHandler(operation: {
            do {
                try await source.initialize(track: track, episodeID: episodeID)
                try Task.checkCancellation()
                return source
            } catch { await source.close(); throw error }
        }, onCancel: { Task { await source.close() } })
    }
    private func initialize(track: VideoTrack, episodeID: String) async throws {
        let progress = state.withLock { $0.progress }
        progress("正在读取视频索引", 0)
        let first = try await fetch(0..<ProgressiveCache.blockSize)
        try Task.checkCancellation()
        guard first.total >= 16, first.total <= MP4Processor.maximumBytes,
              first.data.count == min(first.total, ProgressiveCache.blockSize) else { throw MediaError.invalidMedia }
        let length = first.total
        try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            state.length = length; state.networkBytes = first.data.count
            state.remember(first.data, block: 0); state.available.insert(0)
        }
        var at = 0, count = 0, moovOffset: Int?, moov = Data(), media: [Range<Int>] = [], pssh: [Int] = []
        while at < length {
            try Task.checkCancellation(); count += 1
            guard count <= 4096, length - at >= 8 else { throw MediaError.invalidMedia }
            let header = try await raw(at: at, count: min(16, length - at))
            var size = try integer(header, at: 0, width: 4), width = 8
            if size == 1 { size = try integer(header, at: 8, width: 8); width = 16 }
            else if size == 0 { size = length - at }
            guard size >= width, size <= length - at else { throw MediaError.invalidMedia }
            let type = String(data: header.subdata(in: 4..<8), encoding: .isoLatin1) ?? ""
            if at == 0 && type != "ftyp" { throw MediaError.invalidMedia }
            if ["moof", "mfra", "sidx"].contains(type) { throw MediaError.unsupported }
            if type == "moov" {
                guard moovOffset == nil, size <= 32 * 1024 * 1024 else { throw MediaError.invalidMedia }
                moovOffset = at; moov = try await raw(at: at, count: size)
            } else if type == "mdat" { media.append((at + width)..<(at + size)) }
            else if type == "pssh" { pssh.append(at) }
            at += size
        }
        guard let moovOffset else { throw MediaError.invalidMedia }
        let descriptor = try MP4Processor.streamPlan(length: length, moovOffset: moovOffset, moov: moov,
            media: media, psshOffsets: pssh, encrypted: track.encrypted, spade: track.spadeA,
            expectedDuration: track.expectedDuration)
        let identity = Data((episodeID + ":" + track.definition + ":" + String(length) + ":" + track.spadeA).utf8) + moov + Data(SHA256.hash(data: first.data))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        await cache.acquire(key)
        let acquired = state.withLock { state in
            guard !state.closed else { return false }
            state.cacheKey = key
            return true
        }
        guard acquired else { await cache.release(key); throw CancellationError() }
        try Task.checkCancellation()
        let blockCount = (length + ProgressiveCache.blockSize - 1) / ProgressiveCache.blockSize
        let diskBlocks = await cache.blocks(key: key)
        let mediaStart = media.first?.lowerBound ?? 0
        let initialBlocks = try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            state.available.formUnion(diskBlocks.filter { (0..<blockCount).contains($0) })
            state.plan = descriptor
            state.mediaStart = mediaStart
            return state.memory
        }
        for (index, bytes) in initialBlocks {
            try Task.checkCancellation()
            try? await cache.store(bytes, key: key, block: index)
        }
        if let probe = descriptor.probe, let key = descriptor.key {
            let cipher = try await raw(at: probe.offset, count: probe.size)
            let plain = try HGCrypto.aesCTR(cipher, key: key, iv: probe.iv)
            try MP4Processor.validateStreamProbe(plain, plan: descriptor)
        }
        report()
    }
    func metrics() async -> Metrics { state.withLock { $0.metrics() } }
    /// The new owner's progress reports (a prepared episode is opened before its player exists).
    func observe(_ handler: @escaping Progress) async { state.withLock { $0.progress = handler }; report() }

    /// Verifies `[from, bytes)` relative to the start of picture data, clipped to EOF, with at most one warm range in flight.
    /// False means the request did not complete. Verified blocks remain reusable on a later attempt.
    @discardableResult
    func warm(bytes toOffset: Int, from startOffset: Int = 0) async -> Bool {
        let (mediaStart, length, closed) = state.withLock { ($0.mediaStart, $0.length, $0.closed) }
        guard !closed, !Task.isCancelled, mediaStart < length, toOffset > 0,
              startOffset >= 0, startOffset <= toOffset else { return false }
        let mediaLength = length - mediaStart
        let start = min(startOffset, mediaLength)
        let end = min(toOffset, mediaLength)
        if start == end { return true }
        let size = ProgressiveCache.blockSize
        let last = (mediaStart + end - 1) / size
        var index = (mediaStart + start) / size
        while index <= last {
            switch await warmStep(index, through: last) {
            case .verified(let through): index = through + 1
            case .disk(let key, let expected):
                let block = index
                let cached = await cache.read(key: key, block: block, expected: expected)
                let ready = state.withLock { state in
                    guard !state.closed, !Task.isCancelled else { return false }
                    if let cached {
                        state.remember(cached, block: block); state.available.insert(block)
                        return true
                    }
                    if state.memory[block] != nil { return true }
                    state.available.remove(block)
                    return false
                }
                if ready { index += 1 }
            case .retry: continue
            case .stopped: return false
            }
        }
        return state.withLock { !$0.closed } && !Task.isCancelled
    }

    private func warmStep(_ index: Int, through last: Int) async -> WarmStep {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: WarmStep? = state.withLock { state in
                    guard !state.closed, !Task.isCancelled else { return .stopped }
                    if state.memory[index] != nil { return .verified(index) }
                    let size = ProgressiveCache.blockSize
                    if state.available.contains(index), let key = state.cacheKey {
                        return .disk(key, min(size, state.length - index * size))
                    }
                    let load: UUID, success: WarmStep, failure: WarmStep
                    if let pending = state.pending[index] {
                        load = pending.id; success = .verified(index); failure = .stopped
                    } else if let warmRun = state.warmRun {
                        load = warmRun.id; success = .retry; failure = warmRun.draining ? .retry : .stopped
                    } else {
                        var end = index
                        while end < last, end + 1 - index < Self.runBlocks, !state.known(end + 1) { end += 1 }
                        let blocks = index...end
                        guard let id = startRun(blocks, state: &state) else { return .stopped }
                        state.warmRun = (id, blocks, false)
                        load = id; success = .verified(end); failure = .stopped
                    }
                    state.warmWaiters[waiter] = WarmWaiter(load: load, continuation: continuation, success: success, failure: failure)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let (removed, run) = self.state.withLock { state in
                let removed = state.warmWaiters.removeValue(forKey: waiter)
                let run = removed.flatMap { $0.load == state.warmRun?.id ? state.drainUnusedWarmRun() : nil }
                return (removed, run)
            }
            removed?.continuation.resume(returning: .stopped)
            run?.cancel()
        }
    }

    func read(at offset: Int, count: Int) async throws -> Data {
        try await waitUntilResumed()
        let plan = try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            guard let plan = state.plan, offset >= 0, count >= 0, count <= ProgressiveCache.blockSize,
                  offset <= state.length, count <= state.length - offset else { throw MediaError.invalidMedia }
            if count > 0 {
                let reached = (offset + count - 1) / ProgressiveCache.blockSize
                if state.readAheadFrom < 0 || reached < state.readAheadFrom || reached > state.readAheadFrom + Self.runBlocks * 2 {
                    state.streakStart = reached
                }
                state.readAheadFrom = reached
            }
            return plan
        }
        if count == 0 { return Data() }
        var output = try await raw(at: offset, count: count, scheduleReadAhead: true)
        let end = offset + count
        if let key = plan.key {
            var low = 0, high = plan.samples.count
            while low < high {
                let middle = (low + high) / 2, sample = plan.samples[middle]
                if sample.offset + sample.size <= offset { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < plan.samples.count && plan.samples[index].offset < end {
                try Task.checkCancellation()
                let sample = plan.samples[index]
                let plain: Data
                if let cached = state.withLock({ $0.sampleMemory[sample.offset] }) { plain = cached }
                else {
                    let cipher = try await raw(at: sample.offset, count: sample.size)
                    plain = try HGCrypto.aesCTR(cipher, key: key, iv: sample.iv)
                    state.withLock { state in
                        guard !state.closed, state.sampleMemory[sample.offset] == nil else { return }
                        state.sampleMemory[sample.offset] = plain; state.sampleOrder.append(sample.offset); state.sampleBytes += plain.count
                        while state.sampleBytes > 8 * 1024 * 1024 && state.sampleOrder.count > 1 {
                            let oldest = state.sampleOrder.removeFirst()
                            state.sampleBytes -= state.sampleMemory.removeValue(forKey: oldest)?.count ?? 0
                        }
                    }
                }
                let start = max(offset, sample.offset), stop = min(end, sample.offset + sample.size)
                output.replaceSubrange((start - offset)..<(stop - offset), with: plain.subdata(in: (start - sample.offset)..<(stop - sample.offset)))
                index += 1
            }
        }
        for patch in plan.patches {
            let start = max(offset, patch.offset), stop = min(end, patch.offset + patch.data.count)
            if start < stop {
                output.replaceSubrange((start - offset)..<(stop - offset), with: patch.data.subdata(in: (start - patch.offset)..<(stop - patch.offset)))
            }
        }
        try Task.checkCancellation()
        guard state.withLock({ !$0.closed }) else { throw CancellationError() }
        return output
    }
    private func raw(at offset: Int, count: Int, scheduleReadAhead: Bool = false) async throws -> Data {
        let length = state.withLock { $0.length }
        guard offset >= 0, count >= 0, offset <= length, count <= length - offset else { throw MediaError.invalidMedia }
        var output = Data(); output.reserveCapacity(count)
        var position = offset
        while position < offset + count {
            try await waitUntilResumed()
            let index = position / ProgressiveCache.blockSize
            let bytes = try await block(index, scheduleReadAhead: scheduleReadAhead && position == offset)
            let local = position % ProgressiveCache.blockSize, amount = min(bytes.count - local, offset + count - position)
            guard amount > 0 else { throw MediaError.invalidMedia }
            output.append(bytes.subdata(in: local..<(local + amount))); position += amount
        }
        return output
    }
    private func block(_ index: Int, scheduleReadAhead: Bool) async throws -> Data {
        let reader = UUID()
        return try await withTaskCancellationHandler {
            var checkDisk = true
            var failed: UUID?
            while true {
                let step = try blockStep(index, reader: reader, checkDisk: checkDisk, replacing: failed,
                                         scheduleReadAhead: scheduleReadAhead && checkDisk)
                switch step {
                case .memory(let data): return data
                case .disk(let key, let expected):
                    checkDisk = false
                    if let data = await cache.read(key: key, block: index, expected: expected) {
                        try state.withLock { state in
                            try Task.checkCancellation()
                            guard !state.closed else { throw CancellationError() }
                            state.remember(data, block: index); state.available.insert(index)
                        }
                        report()
                        return data
                    }
                case .loading(let pending, let retry):
                    do {
                        let parts = try await pending.task.value
                        try Task.checkCancellation()
                        guard state.withLock({ !$0.closed }) else { throw CancellationError() }
                        return parts[pending.position]
                    } catch {
                        try Task.checkCancellation()
                        guard retry, failed == nil else { throw error }
                        checkDisk = false
                        failed = pending.id
                    }
                }
            }
        } onCancel: {
            self.cancelWarmReader(reader)
        }
    }

    private func blockStep(_ index: Int, reader: UUID, checkDisk: Bool, replacing failed: UUID?, scheduleReadAhead: Bool) throws -> BlockStep {
        try state.withLock { state in
            try Task.checkCancellation()
            guard !state.closed else { throw CancellationError() }
            defer { if scheduleReadAhead { extendReadAhead(&state) } }
            if let data = state.memory[index] { return .memory(data) }
            let size = ProgressiveCache.blockSize
            let start = index * size, end = min(start + size, state.length)
            guard start >= 0, start < end else { throw MediaError.invalidMedia }
            if let pending = state.pending[index], pending.id == failed { state.pending.removeValue(forKey: index) }
            let existing = state.pending[index]
            if checkDisk, let key = state.cacheKey, state.warmRun == nil || existing?.id != state.warmRun?.id {
                return .disk(key, end - start)
            }
            if let existing {
                if existing.id == state.warmRun?.id { state.warmReaders.insert(reader) }
                return .loading(existing, retry: true)
            }
            let identifier = UUID(), length = state.length
            let task = Task { [weak self, fetch] in
                do {
                    try Task.checkCancellation()
                    let reply = try await fetch(start..<end)
                    try Task.checkCancellation()
                    guard reply.total == length, reply.data.count == end - start else { throw MediaError.invalidMedia }
                    try await self?.completeBlock(reply.data, index: index, identifier: identifier)
                    return [reply.data]
                } catch {
                    self?.failBlock(index, identifier: identifier)
                    throw error
                }
            }
            let pending = Pending(id: identifier, task: task, position: 0)
            state.pending[index] = pending
            return .loading(pending, retry: false)
        }
    }

    private func completeBlock(_ data: Data, index: Int, identifier: UUID) async throws {
        let (key, waiters) = try state.withLock { state in
            guard !state.closed, state.pending[index]?.id == identifier else { throw CancellationError() }
            state.pending.removeValue(forKey: index); state.networkBytes += data.count
            state.remember(data, block: index); state.available.insert(index)
            return (state.cacheKey, state.takeWarmWaiters(identifier))
        }
        for waiter in waiters { waiter.continuation.resume(returning: waiter.success) }
        report()
        if let key { try? await cache.store(data, key: key, block: index) }
    }

    private func failBlock(_ index: Int, identifier: UUID) {
        let waiters = state.withLock { state in
            if state.pending[index]?.id == identifier { state.pending.removeValue(forKey: index) }
            return state.takeWarmWaiters(identifier)
        }
        for waiter in waiters { waiter.continuation.resume(returning: waiter.failure) }
    }

    private func cancelWarmReader(_ reader: UUID) {
        let run = state.withLock { state -> Task<[Data], Error>? in
            guard state.warmReaders.remove(reader) != nil else { return nil }
            return state.drainUnusedWarmRun()
        }
        run?.cancel()
    }

    // MARK: Read-ahead

    private func extendReadAhead(_ state: inout State) {
        guard readAhead > 0, state.readAheadFrom >= 0, !state.paused, !state.closed, state.length > 0 else { return }
        let size = ProgressiveCache.blockSize
        let window = min(readAhead, size * (1 + 2 * max(0, state.readAheadFrom - state.streakStart)))
        let ahead = max(1, window / size)
        let last = min((state.length - 1) / size, state.readAheadFrom + ahead)
        let runLength = min(Self.runBlocks, ahead)
        var index = state.readAheadFrom + 1
        while index <= last, state.runs.count < Self.concurrentRuns {
            if state.known(index) { index += 1; continue }
            var end = index
            while end < last, end + 1 - index < runLength, !state.known(end + 1) { end += 1 }
            startRun(index...end, state: &state)
            index = end + 1
        }
    }

    /// One HTTP range for several neighbouring blocks; each block can be awaited on its own.
    @discardableResult
    private func startRun(_ blocks: ClosedRange<Int>, state: inout State) -> UUID? {
        let size = ProgressiveCache.blockSize
        let start = blocks.lowerBound * size, end = min((blocks.upperBound + 1) * size, state.length)
        guard start < end else { return nil }
        let provider = fetch, expectedLength = state.length, identifier = UUID()
        let run = Task { () throws -> [Data] in
            try Task.checkCancellation()
            let reply = try await provider(start..<end)
            try Task.checkCancellation()
            guard reply.total == expectedLength, reply.data.count == end - start else { throw MediaError.invalidMedia }
            return stride(from: 0, to: reply.data.count, by: size).map { reply.data.subdata(in: $0..<min($0 + size, reply.data.count)) }
        }
        state.runs[identifier] = run
        for (position, index) in blocks.enumerated() {
            state.pending[index] = Pending(id: identifier, task: run, position: position)
        }
        Task { [weak self] in
            let result = await run.result
            await self?.finishRun(blocks, identifier: identifier, result: result)
        }
        return identifier
    }

    private func finishRun(_ blocks: ClosedRange<Int>, identifier: UUID, result: Result<[Data], Error>) async {
        let completion = state.withLock { state -> (String?, [(Int, Data)], [WarmWaiter])? in
            guard !state.closed, state.runs.removeValue(forKey: identifier) != nil else { return nil }
            if state.warmRun?.id == identifier { state.warmRun = nil; state.warmReaders.removeAll() }
            var stored: [(Int, Data)] = []
            for (position, index) in blocks.enumerated() where state.pending[index]?.id == identifier {
                state.pending.removeValue(forKey: index)
                if case .success(let parts) = result, parts.indices.contains(position) {
                    state.networkBytes += parts[position].count
                    state.remember(parts[position], block: index); state.available.insert(index); stored.append((index, parts[position]))
                }
            }
            return (state.cacheKey, stored, state.takeWarmWaiters(identifier))
        }
        guard let (key, stored, waiters) = completion else { return }
        let completed = stored.count == blocks.count
        for waiter in waiters { waiter.continuation.resume(returning: completed ? waiter.success : waiter.failure) }
        if !stored.isEmpty { report() }
        if let key { for (index, data) in stored { try? await cache.store(data, key: key, block: index) } }
        if completed { state.withLock { extendReadAhead(&$0) } }
    }
    private func report() {
        guard let (progress, value) = state.withLock({ $0.closed ? nil : ($0.progress, $0.metrics()) }) else { return }
        progress("边下边播", min(1, Double(value.availableBytes) / Double(max(1, value.length))))
    }
    private func integer(_ bytes: Data, at: Int, width: Int) throws -> Int {
        guard at >= 0, width <= bytes.count - at else { throw MediaError.invalidMedia }
        var value: UInt64 = 0
        for byte in bytes.subdata(in: at..<(at + width)) { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw MediaError.invalidMedia }; return Int(value)
    }
    func setPaused(_ value: Bool) async {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            guard !state.closed else { return [] }
            state.paused = value
            guard !value else { return [] }
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            extendReadAhead(&state)
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func waitUntilResumed() async throws {
        try Task.checkCancellation()
        let paused = try state.withLock { state in
            guard !state.closed else { throw CancellationError() }
            return state.paused
        }
        guard paused else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = state.withLock { state in
                    if Task.isCancelled || state.closed { return .failure(CancellationError()) }
                    if !state.paused { return .success(()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }, onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        })
        try Task.checkCancellation()
        guard state.withLock({ !$0.closed }) else { throw CancellationError() }
    }

    func close() async {
        let closing = state.withLock { state -> (String?, [CheckedContinuation<Void, Error>], [WarmWaiter], [Task<[Data], Error>])? in
            guard !state.closed else { return nil }
            state.closed = true
            let tasks = Array(state.runs.values) + state.pending.values.filter { state.runs[$0.id] == nil }.map(\.task)
            let closing = (state.cacheKey, Array(state.waiters.values), Array(state.warmWaiters.values), tasks)
            state.cacheKey = nil; state.waiters.removeAll(); state.warmWaiters.removeAll()
            state.pending.removeAll(); state.runs.removeAll(); state.warmRun = nil; state.warmReaders.removeAll()
            state.memory.removeAll(); state.sampleMemory.removeAll(); state.plan = nil
            return closing
        }
        guard let (key, waiters, warmWaiters, tasks) = closing else { return }
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        for waiter in warmWaiters { waiter.continuation.resume(returning: .stopped) }
        for task in tasks { task.cancel() }
        if let key { await cache.release(key) }
    }
}
