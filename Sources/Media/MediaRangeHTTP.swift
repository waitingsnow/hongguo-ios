// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MediaRangeReply: Sendable {
    let data: Data
    let total: Int
    /// Where the bytes actually came from after redirects; nil for test sources.
    var address: URL? = nil
}

/// A 4xx answer: the signed address expired or was refused, so asking it again cannot help.
struct MediaAddressRejected: Error { let status: Int }

/// Bounded HTTP 206 reads. Never downloads a whole response from a server ignoring Range.
/// Every range goes through one shared session, so connections (and HTTP/2 streams) are reused: the old one-session-
/// per-block design paid a DNS, TCP and TLS setup for each 256 KB, which made start-up and buffering slow.
final class MediaRangeHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MediaRangeHTTP(configuration: nil)
    private var session: URLSession!
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    private init(configuration supplied: URLSessionConfiguration?) {
        super.init()
        let configuration = supplied ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        return ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// An allowed media host may answer 302 to another CDN for load balancing. Seen so far: *.vegslb.com, *.bdcgslb.com
    /// (2026-11-06), *.idouyinvod.com and *.smtcdns.com (2026-11-08). The set changes without notice and rejecting an
    /// unlisted CDN made episodes fail at random, so any public HTTPS host name is followed. The first URL must still be
    /// allowed(); credentials are never forwarded, and every reply is checked for an exact 206 range and the same total.
    static func allowedAfterRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        if allowed(url) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), host.count <= 253,
              !host.contains(":"), !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let top = labels.last, top.contains(where: \.isLetter) else { return false }
        return !["localhost", "local", "internal", "lan", "home", "arpa"].contains(String(top))
    }

    /// Range read with retries for transient failures. A CDN switch or short network drop recovers on its own within a
    /// few seconds. A refused address (`MediaAddressRejected`) is not retried.
    static func fetchRetrying(_ url: URL, range: Range<Int>, attempts: Int = 5,
                              configuration: URLSessionConfiguration? = nil) async throws -> MediaRangeReply {
        var delay: UInt64 = 300_000_000
        for attempt in 1... {
            do { return try await fetch(url, range: range, configuration: configuration) }
            catch let error as MediaError where (error == .transport || error == .invalidMedia) && attempt < attempts {
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 2_000_000_000)
            }
        }
        throw MediaError.transport
    }
    static func fetch(_ url: URL, range: Range<Int>, configuration: URLSessionConfiguration? = nil) async throws -> MediaRangeReply {
        guard allowed(url) else { throw MediaError.invalidMedia }
        return try await perform(url, range: range, timeout: 15, configuration: configuration)
    }
    /// For the CDN address an earlier reply was redirected to. A dead edge fails fast so the caller can go back to
    /// the scheduling address.
    static func fetch(redirected url: URL, range: Range<Int>) async throws -> MediaRangeReply {
        guard allowedAfterRedirect(url) else { throw MediaError.invalidMedia }
        return try await perform(url, range: range, timeout: 6, configuration: nil)
    }
    private static func perform(_ url: URL, range: Range<Int>, timeout: TimeInterval, configuration: URLSessionConfiguration?) async throws -> MediaRangeReply {
        guard range.lowerBound >= 0, !range.isEmpty, range.count <= 32 * 1024 * 1024,
              range.upperBound <= MP4Processor.maximumBytes else { throw MediaError.invalidMedia }
        guard let configuration else { return try await shared.run(url, range: range, timeout: timeout) }
        let client = MediaRangeHTTP(configuration: configuration)
        defer { client.session.finishTasksAndInvalidate() }
        return try await client.run(url, range: range, timeout: timeout)
    }

    private func run(_ url: URL, range: Range<Int>, timeout: TimeInterval) async throws -> MediaRangeReply {
        let transfer = Transfer(range: range)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { start(transfer, url: url, timeout: timeout, continuation: $0) }
        }, onCancel: { transfer.cancel() })
    }
    private func start(_ transfer: Transfer, url: URL, timeout: TimeInterval, continuation: CheckedContinuation<MediaRangeReply, Error>) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(transfer.rangeHeader, forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        lock.lock(); transfers[task.taskIdentifier] = transfer; lock.unlock()
        guard transfer.begin(task, continuation: continuation) else {
            lock.lock(); transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
            continuation.resume(throwing: CancellationError()); return
        }
        task.resume()
    }
    private func transfer(_ task: URLSessionTask) -> Transfer? { lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier] }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let transfer = transfer(task), let url = request.url, Self.allowedAfterRedirect(url) else {
            transfer(task)?.failure = MediaError.transport; completionHandler(nil); return
        }
        var safe = request; safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(transfer.rangeHeader, forHTTPHeaderField: "Range")
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask) else { completionHandler(.cancel); return }
        let range = transfer.range
        if let http = response as? HTTPURLResponse, (400..<500).contains(http.statusCode), http.statusCode != 416 {
            transfer.failure = MediaAddressRejected(status: http.statusCode); completionHandler(.cancel); return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let address = http.url, Self.allowedAfterRedirect(address),
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.contentRange(header), parsed.start == range.lowerBound,
              parsed.total > 0, parsed.total <= MP4Processor.maximumBytes,
              parsed.end == min(range.upperBound, parsed.total) - 1,
              parsed.end >= parsed.start else {
            transfer.failure = MediaError.transport; completionHandler(.cancel); return
        }
        transfer.total = parsed.total; transfer.expected = parsed.end - parsed.start + 1; transfer.address = address
        guard response.expectedContentLength < 0 || response.expectedContentLength == Int64(transfer.expected),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            transfer.failure = MediaError.invalidMedia; completionHandler(.cancel); return
        }
        transfer.bytes.reserveCapacity(transfer.expected)
        completionHandler(.allow)
    }
    static func contentRange(_ text: String) -> (start: Int, end: Int, total: Int)? {
        guard text.hasPrefix("bytes "), text.count <= 100 else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int(parts[1]) else { return nil }
        let limits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard limits.count == 2, let start = Int(limits[0]), let end = Int(limits[1]), start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(dataTask), transfer.failure == nil else { return }
        guard data.count <= transfer.expected - transfer.bytes.count else { transfer.failure = MediaError.invalidMedia; dataTask.cancel(); return }
        transfer.bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        transfer?.complete(error: error)
    }

    /// One range request's state. Delegate callbacks arrive on the session's serial queue; cancellation may come from
    /// any thread, so the continuation and task are guarded.
    private final class Transfer: @unchecked Sendable {
        let range: Range<Int>
        var rangeHeader: String { "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
        var failure: Error?
        var bytes = Data()
        var total = 0
        var expected = 0
        var address: URL?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<MediaRangeReply, Error>?
        private var task: URLSessionTask?
        private var cancelled = false
        init(range: Range<Int>) { self.range = range }

        func begin(_ task: URLSessionTask, continuation: CheckedContinuation<MediaRangeReply, Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.task = task; self.continuation = continuation; return true
        }
        func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
        func complete(error: Error?) {
            lock.lock(); let completion = continuation; continuation = nil; task = nil; let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { completion?.resume(throwing: CancellationError()) }
            else if let failure { completion?.resume(throwing: failure) }
            else if error != nil { completion?.resume(throwing: MediaError.transport) }
            else if total > 0, bytes.count == expected { completion?.resume(returning: MediaRangeReply(data: bytes, total: total, address: address)) }
            else { completion?.resume(throwing: MediaError.invalidMedia) }
        }
    }
}
