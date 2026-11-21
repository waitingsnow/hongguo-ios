import SwiftUI
import Nuke
import NukeUI

/// Covers and avatars load through Nuke: decoded images stay in memory and the original bytes go to a disk cache,
/// so a relaunch paints covers without touching the network.
enum ImageLoading {
    static func configure() {
        let configuration = ImagePipeline.Configuration.withDataCache(name: "com.ooiua.hongguo.images", sizeLimit: 300 * 1024 * 1024)
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }

    private static let prefetcher = ImagePrefetcher(destination: .diskCache)

    /// Warms the disk cache for covers about to scroll into view.
    static func prefetch(_ addresses: [String]) {
        let urls = addresses.compactMap(url)
        if !urls.isEmpty { prefetcher.startPrefetching(with: urls) }
    }

    static func url(_ address: String) -> URL? {
        guard !address.isEmpty, let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }
}

/// A remote image that fills exactly the frame its parent gives it. The scaled picture never widens the layout, and
/// touches outside the frame are not taken (a fill-scaled cover used to cover the search bar above it).
struct RemoteImage<Placeholder: View>: View {
    let address: String
    var priority: ImageRequest.Priority = .normal
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        Color.clear
            .overlay {
                LazyImage(url: ImageLoading.url(address)) { state in
                    if let image = state.image { image.resizable().scaledToFill() } else { placeholder() }
                }
                .priority(priority)
                .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
