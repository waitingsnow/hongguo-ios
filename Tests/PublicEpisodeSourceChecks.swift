import Foundation

private enum GuestFixture {
    static let series = "7000000000000000001", open = "7000000000000000002", locked = "7000000000000000003"
    static let media = "https://v3-hgweb.qznovelvod.com/example.mp4"

    static func page(episode: String = open, access: [String: Any] = ["pcLoginRequired": false, "pcAuthenticatedPlayback": false],
                     metadataID: String = open, listed: Bool = true) throws -> String {
        var loader: [String: Any] = [
            "isSuccess": true, "series_id": series, "vid": episode, "req": access,
            "seriesDetail": ["series_id": series, "accessible_episode_cnt": 1, "vid_list": [open, locked]]
        ]
        if listed {
            loader["publicVideoSeo"] = ["available": true, "seriesId": series, "itemId": metadataID,
                                        "durationSeconds": 125.14, "width": 360, "height": 640,
                                        "main_url": "https://v3-hgweb.qznovelvod.com/trailer.mp4"]
        }
        let bytes = try ProtocolJSON.data(["loaderData": ["player_(series_id)/(vid)/page": loader]])
        return "<script>_ROUTER_DATA = " + String(decoding: bytes, as: UTF8.self) + ";</script>"
    }
}

private class GuestPlaybackProtocol: URLProtocol, @unchecked Sendable {
    var mobileBody: Data { Data() }
    var guestHeaders: [String: String] { [:] }
    var singleStatus: Int? { nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if url.host == URL(string: WebsiteCatalog.base)?.host {
            precondition(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil)
            for header in ["Authorization", "x-medusa", "x-helios", "x-gorgon"] {
                precondition(request.value(forHTTPHeaderField: header) == nil)
            }
            if url.path == "/api/video/protected/fallback-play-info" {
                precondition(request.httpMethod == "POST")
                precondition(body() == Data(#"{"item_id":"7000000000000000002"}"#.utf8))
                respond(try! ProtocolJSON.data(["base_resp": ["StatusCode": 0], "main_url": GuestFixture.media]), headers: guestHeaders)
            } else {
                let episode = url.lastPathComponent
                precondition(request.httpMethod == "GET" && url.path == "/player/\(GuestFixture.series)/\(episode)")
                respond(Data(try! GuestFixture.page(episode: episode, metadataID: episode).utf8))
            }
        } else if url.path.contains("/device_register") {
            respond(Data(#"{"code":0,"device_id_str":"1111111111111111","install_id_str":"2222222222222222"}"#.utf8))
        } else if url.absoluteString.hasPrefix(PlaybackRegistration.activateURL) {
            respond(Data("{}".utf8))
        } else if url.path == URL(string: DramaAPI.mobileVideoURL)?.path {
            respond(mobileBody)
        } else if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                    DramaAPI.singleVideoPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            if let singleStatus {
                let response = HTTPURLResponse(url: url, statusCode: singleStatus, httpVersion: nil,
                                               headerFields: ["Content-Length": "100", "Content-Type": "application/json",
                                                              "X-Content-Type-Options": "nosniff"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            precondition(url.host == DramaAPI.playbackHost || url.host == DramaAPI.playbackRetryHost)
            respond(Data())
        }
    }

    private func body() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { return nil }
            if read == 0 { return body }
            body.append(contentsOf: buffer.prefix(read))
        }
    }

    private func respond(_ body: Data, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: headers.merging(["Content-Length": String(body.count)]) { value, _ in value })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class GuestBackoffProtocol: GuestPlaybackProtocol, @unchecked Sendable {
    override var guestHeaders: [String: String] { ["Retry-After": "5"] }
}

private final class AppCaptchaProtocol: GuestPlaybackProtocol, @unchecked Sendable {
    override var mobileBody: Data { Data(#"{"code":0,"data":{"verify_center_decision_conf":"fixture"}}"#.utf8) }
}

private final class AppRefusalProtocol: GuestPlaybackProtocol, @unchecked Sendable {
    override var singleStatus: Int? { 403 }
}

private final class AppQualityProtocol: GuestPlaybackProtocol, @unchecked Sendable {
    override var mobileBody: Data {
        let rows = [720, 1080].map { side -> [String: Any] in
            ["codec_type": "h264", "vwidth": side, "vheight": side * 16 / 9, "definition": "\(side)p",
             "main_url": "https://v1.qznovelvod.com/\(side).mp4", "encrypt_info": ["encrypt": false]]
        }
        return try! ProtocolJSON.data(["code": 0, "data": [GuestFixture.open: ["video_model": ["video_list": rows]]]])
    }
}

func checkPublicEpisodes(resources: URL) async throws {
    let series = GuestFixture.series, episode = GuestFixture.open, locked = GuestFixture.locked
    func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Ineligible public episode was accepted") }
        catch is PublicEpisodeSource.Failure { }
        catch { preconditionFailure(error.localizedDescription) }
    }
    let info = try PublicEpisodeSource.episodeInfo(html: GuestFixture.page(), seriesID: series, episodeID: episode)
    precondition(info.duration == .declared(125.14) && info.shortSide == 360)
    let unlisted = try PublicEpisodeSource.episodeInfo(html: GuestFixture.page(listed: false), seriesID: series, episodeID: episode)
    precondition(unlisted.duration == .unlisted && unlisted.shortSide == 0)
    rejected { _ = try PublicEpisodeSource.episodeInfo(html: GuestFixture.page(), seriesID: series, episodeID: locked) }
    rejected { _ = try PublicEpisodeSource.episodeInfo(html: GuestFixture.page(metadataID: locked), seriesID: series, episodeID: episode) }
    for access: [String: Any] in [[:], ["pcLoginRequired": false], ["pcLoginRequired": 0, "pcAuthenticatedPlayback": false],
                                  ["pcLoginRequired": true, "pcAuthenticatedPlayback": false],
                                  ["pcLoginRequired": false, "pcAuthenticatedPlayback": true]] {
        rejected { _ = try PublicEpisodeSource.episodeInfo(html: GuestFixture.page(access: access), seriesID: series, episodeID: episode) }
    }

    func track(_ url: String, expiry: Int = 1010) throws -> VideoTrack {
        let bytes = try ProtocolJSON.data(["base_resp": ["StatusCode": 0], "main_url": url, "url_expire": expiry])
        return try PublicEpisodeSource.track(response: bytes, info: info, now: Date(timeIntervalSince1970: 1000))
    }
    rejected { _ = try track(GuestFixture.media, expiry: 995) }
    for invalid in ["https://qznovelvod.com.example/video.mp4", "http://v3.qznovelvod.com/video.mp4",
                    "https://name@fqnovelvod.com/video.mp4", "https://fqnovelvod.com:444/video.mp4", "https://127.0.0.1/video.mp4"] {
        rejected { _ = try track(invalid) }
    }

    func api(_ fixture: GuestPlaybackProtocol.Type) -> DramaAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [fixture]
        return DramaAPI(resourceDirectory: resources, configuration: config)
    }
    let guestAPI = api(GuestPlaybackProtocol.self)
    let guest = try await guestAPI.track(episodeID: episode, seriesID: series, quality: .p1080)
    let guestTrace = await guestAPI.lastPlaybackTrace
    precondition(guestTrace.contains("S=failed") && guestTrace.hasSuffix(" W=ok"), guestTrace)
    precondition(guest.url.absoluteString == GuestFixture.media && guest.expectedDuration == info.duration &&
                 guest.shortSide == 360 && !guest.encrypted && guest.spadeA.isEmpty)
    do {
        _ = try await guestAPI.track(episodeID: locked, seriesID: series)
        preconditionFailure("Locked episode reached the guest lookup")
    } catch PublicEpisodeSource.Failure.unavailable { }
    do {
        _ = try await api(GuestBackoffProtocol.self).track(episodeID: episode, seriesID: series)
        preconditionFailure("Guest Retry-After header was ignored")
    } catch PublicEpisodeSource.Failure.rateLimited { }
    do {
        _ = try await api(AppCaptchaProtocol.self).track(episodeID: episode, seriesID: series)
        preconditionFailure("App verification was ignored")
    } catch is DramaAPI.PlaybackRefusal { }
    do {
        _ = try await api(AppRefusalProtocol.self).track(episodeID: episode, seriesID: series)
        preconditionFailure("App refused playback before sending its body")
    } catch let error as DramaAPI.PlaybackRefusal { precondition(error.localizedDescription.contains("403")) }
    let qualityAPI = api(AppQualityProtocol.self)
    for quality in [VideoQuality.p720, .p1080] {
        let app = try await qualityAPI.track(episodeID: episode, seriesID: series, quality: quality)
        precondition(app.shortSide == quality.shortSide && app.expectedDuration == nil)
    }
    print("PASS public playback: guest eligibility, upstream duration, app disconnect, captcha, backoff and quality preference")
}
