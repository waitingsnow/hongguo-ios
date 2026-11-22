import SwiftUI
import Nuke

/// Covers and avatars load through Nuke: decoded images stay in memory and the original bytes go to a disk cache,
/// so a relaunch paints covers without touching the network.
enum ImageLoading {
    static func configure() {
        let configuration = ImagePipeline.Configuration.withDataCache(name: "com.ooiua.hongguo.images", sizeLimit: 300 * 1024 * 1024)
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }

    static func request(_ address: String, priority: ImageRequest.Priority = .normal) -> ImageRequest? {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        var request = ImageRequest(url: url, priority: priority)
        if url.scheme == "https", url.user == nil, url.port == nil,
           url.host?.hasSuffix("-reading-sign.fqnovelpic.com") == true,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let query = components.percentEncodedQueryItems,
           query.contains(where: { $0.name == "x-expires" }), query.contains(where: { $0.name == "x-signature" }) {
            let stable = query.filter { $0.name != "x-expires" && $0.name != "x-signature" }
            components.percentEncodedQueryItems = stable.isEmpty ? nil : stable
            request.imageID = components.string
        }
        return request
    }
}

@MainActor
final class CoverPrefetchWindow {
    private let pipeline: ImagePipeline
    private var targets: [ImageRequest] = []
    private var attempted: Set<URL> = []
    private var active: [URL: Task<Void, Never>] = [:]

    init(pipeline: ImagePipeline = .shared) { self.pipeline = pipeline }

    deinit { active.values.forEach { $0.cancel() } }

    func update(_ addresses: [String]) {
        targets = addresses.prefix(9).compactMap { ImageLoading.request($0, priority: .low) }
        let urls = Set(targets.compactMap(\.url))
        for url in attempted.subtracting(urls) {
            active.removeValue(forKey: url)?.cancel()
        }
        attempted.formIntersection(urls)
        startPending()
    }

    private func startPending() {
        for request in targets {
            guard active.count < 2 else { return }
            guard let url = request.url, attempted.insert(url).inserted else { continue }
            if let cached = pipeline.cache[request], !cached.isPreview { continue }
            active[url] = Task { [weak self, pipeline] in
                guard !Task.isCancelled else { return }
                _ = try? await pipeline.image(for: request)
                guard !Task.isCancelled, let self else { return }
                self.active[url] = nil
                self.startPending()
            }
        }
    }
}

private enum LibraryCoverOwnerKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var libraryCoverOwner: String? {
        get { self[LibraryCoverOwnerKey.self] }
        set { self[LibraryCoverOwnerKey.self] = newValue }
    }
}

/// A remote image that fills exactly the frame its parent gives it. The scaled picture never widens the layout, and
/// touches outside the frame are not taken (a fill-scaled cover used to cover the search bar above it).
struct RemoteImage<Placeholder: View>: View {
    let address: String
    var priority: ImageRequest.Priority = .normal
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.libraryCoverOwner) private var owner
    @State private var displayed: Displayed?

    private struct Displayed {
        let owner: String?
        let imageID: String?
        let image: UIImage
    }

    private struct LoadID: Equatable {
        let owner: String?
        let address: String
        let priority: ImageRequest.Priority
    }

    var body: some View {
        let request = ImageLoading.request(address, priority: priority)
        let cached = request.flatMap { ImagePipeline.shared.cache[$0] }
        let retained = displayed.flatMap { item in
            item.owner == owner && (owner != nil || item.imageID == request?.imageID) ? item.image : nil
        }
        let image = cached.flatMap { $0.isPreview ? nil : $0.image } ?? retained
        return Color.clear
            .overlay {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { placeholder() }
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: LoadID(owner: owner, address: address, priority: priority)) {
                guard let request else { return }
                if let displayed, displayed.owner == owner, displayed.imageID == request.imageID { return }
                let image: UIImage
                if let cached = ImagePipeline.shared.cache[request], !cached.isPreview {
                    image = cached.image
                } else {
                    guard let loaded = try? await ImagePipeline.shared.image(for: request) else { return }
                    image = loaded
                }
                guard !Task.isCancelled else { return }
                displayed = Displayed(owner: owner, imageID: request.imageID, image: image)
            }
    }
}
