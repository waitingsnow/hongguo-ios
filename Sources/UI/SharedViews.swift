import SwiftUI

enum PortraitVideoPosition: String, CaseIterable, Identifiable {
    static let key = "playback.portraitVideoPosition"
    case top, center, bottom

    var id: Self { self }
    var title: String {
        switch self {
        case .top: "顶部"
        case .center: "中间"
        case .bottom: "底部"
        }
    }
}

struct PortraitVideoPositionPicker: View {
    @AppStorage(PortraitVideoPosition.key) private var position: PortraitVideoPosition = .center

    var body: some View {
        Picker("竖屏横片位置", selection: $position) {
            ForEach(PortraitVideoPosition.allCases) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("playback.portraitVideoPosition")
    }
}

struct PlaybackPictureLayout {
    enum Context {
        case player, feed

        var header: CGFloat { self == .player ? 54 : 64 }
        var footer: CGFloat { self == .player ? 124 : 142 }
        var accessoryRoom: CGFloat { 44 }
        var interactionColumnBottom: CGFloat { self == .player ? 118 : 66 }
        var interactionSpacing: CGFloat { self == .player ? 4 : 16 }
    }

    let canvas: CGSize
    let insets: EdgeInsets
    let position: PortraitVideoPosition
    let context: Context

    func portraitWideFrame(for video: CGSize) -> CGRect? {
        guard canvas.height > canvas.width, video.width > video.height, video.height > 0 else { return nil }
        let top = insets.top + context.header
        let bottom = canvas.height - insets.bottom - context.footer - context.accessoryRoom
        let safeWidth = canvas.width - insets.leading - insets.trailing
        guard bottom > top, safeWidth > 0 else { return nil }
        let aspect = video.width / video.height
        let availableHeight = bottom - top
        let height = min(safeWidth / aspect, availableHeight - min(64, availableHeight * 0.18))
        let width = height * aspect
        let lastY = bottom - height
        let y: CGFloat
        switch position {
        case .top: y = top
        case .center:
            let margin = min(24, (lastY - top) / 2)
            y = min(max(top + margin, (canvas.height - height) / 2), lastY - margin)
        case .bottom: y = lastY
        }
        return CGRect(x: insets.leading + (safeWidth - width) / 2, y: y, width: width, height: height)
    }

    func frame(for video: CGSize) -> CGRect {
        portraitWideFrame(for: video) ?? CGRect(origin: .zero, size: canvas)
    }

    func overlapsInteractionColumn(_ picture: CGRect?) -> Bool {
        guard let picture else { return false }
        return picture.maxY > interactionColumnTop
    }

    private var interactionColumnTop: CGFloat {
        canvas.height - insets.bottom - context.interactionColumnBottom - (3 * 44 + 2 * context.interactionSpacing)
    }

    func danmakuInsets(around picture: CGRect?) -> EdgeInsets {
        let defaultTop: CGFloat = 68
        guard let picture else { return EdgeInsets(top: defaultTop, leading: 0, bottom: 0, trailing: 0) }
        let laneSpace: CGFloat = 92
        let below = picture.maxY + context.accessoryRoom
        let top: CGFloat
        if picture.minY - (insets.top + defaultTop) >= laneSpace { top = defaultTop }
        else if canvas.height - insets.bottom - context.footer - below >= laneSpace { top = below - insets.top }
        else { top = max(defaultTop, picture.minY - insets.top + 8) }
        let overlapsColumn = !overlapsInteractionColumn(picture) && insets.top + top + laneSpace > interactionColumnTop
        return EdgeInsets(top: top, leading: 0, bottom: 0, trailing: overlapsColumn ? 64 : 0)
    }
}

extension View {
    func playbackPictureFrame(_ frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

enum AppSymbol {
    static func favorite(_ selected: Bool = false) -> String { selected ? "star.fill" : "star" }
    static func danmaku(_ enabled: Bool) -> String { enabled ? "list.bullet.rectangle.fill" : "list.bullet.rectangle" }
    static let history = "clock.arrow.circlepath"
    static let settings = "gearshape"
}

extension Font {
    static let playbackHeading = Font.subheadline.weight(.medium)
}

struct FollowDramaButton: View {
    let seriesID: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.discussionSeriesFavoriteCount) private var seriesFavoriteCount

    var body: some View {
        let count = seriesFavoriteCount?.seriesID == seriesID ? seriesFavoriteCount?.count : nil
        Button(action: action) {
            InteractionButtonIcon(symbol: AppSymbol.favorite(selected), count: count)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "已追" : "追剧")
        .accessibilityValue(count.map { "\($0) 人收藏" } ?? "暂未取得收藏数")
        .accessibilityHint(selected ? "取消本机收藏" : "添加本机收藏")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct InteractionButtonIcon: View {
    let symbol: String
    let count: Int?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(height: 23)
                .accessibilityHidden(true)
            Text(verbatim: count.map(Self.countLabel) ?? "")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(height: 13)
        }
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private static func countLabel(_ count: Int) -> String {
        guard count >= 1_000 else { return String(count) }
        let millions = count >= 1_000_000
        let divisor = millions ? 1_000_000 : 1_000
        let whole = count / divisor
        let tenth = (count % divisor) / (divisor / 10)
        let number = tenth == 0 ? "\(whole)" : "\(whole).\(tenth)"
        return number + (millions ? "m" : "k")
    }
}

struct AppControlIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.title3.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct PlaybackEpisodeStrip: View {
    let title: String
    let detail: String
    var symbol = "rectangle.stack"
    var chevron = "chevron.up"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.subheadline.weight(.medium))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: chevron).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white).padding(.horizontal, 14).frame(minHeight: 44)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct PosterView: View {
    let drama: Drama
    var ratio: CGFloat = 0.72
    var body: some View {
        RemoteImage(address: drama.coverURL) {
            ZStack {
                LinearGradient(colors: [Color(hex: 0xDDC3AF), Color(hex: 0x8E7062)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) { Image(systemName: "film").font(.title); Text(drama.title).font(.caption).multilineTextAlignment(.center).lineLimit(3) }.foregroundStyle(.white.opacity(0.9)).padding(12)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
    }
}

struct DramaPoster: View {
    let drama: Drama
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterView(drama: drama)
                .overlay(alignment: .bottomTrailing) {
                    if drama.episodeCount > 0 { Text("全 \(drama.episodeCount) 集").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 4).background(.black.opacity(0.62), in: Capsule()).padding(7) }
                }
            Text(drama.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(model.appearance.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Library and account lists use the 剧场 grid: three posters across on a phone, more on wider screens such as
/// the unfolded iPhone Duo, so posters keep a phone-like size instead of stretching.
let threePosterColumns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 12, alignment: .top)]

struct LibraryPosterCell: View {
    let drama: Drama
    var subtitle: String?
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DramaPoster(drama: drama)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(model.appearance.accent).lineLimit(1) }
        }
    }
}

struct SearchEntry: View {
    var title = "搜索剧名，发现好故事"
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationLink { SearchView() } label: {
            HStack(spacing: 10) { Image(systemName: "magnifyingglass").font(.body.weight(.medium)); Text(title).font(.subheadline); Spacer(); Text("搜索").font(.caption.weight(.semibold)) }
                .foregroundStyle(model.appearance.muted).padding(.horizontal, 16).frame(minHeight: 48).background(model.appearance.soft, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("搜索短剧")
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 27)).foregroundStyle(model.appearance.muted)
            Text(message).font(.subheadline).foregroundStyle(model.appearance.muted).multilineTextAlignment(.center).textSelection(.enabled)
            Button("重新加载", action: retry).buttonStyle(.borderedProminent).tint(model.appearance.accent)
        }.frame(maxWidth: .infinity).padding(24).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(model.appearance.accent.opacity(0.7))
            Text(title).font(.headline).foregroundStyle(model.appearance.ink)
            Text(message).font(.subheadline).foregroundStyle(model.appearance.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 46).padding(.horizontal, 20)
    }
}

struct LoadMoreView: View {
    @ObservedObject var loader: CatalogLoader
    /// Retries a failed page; the list requests the others itself while scrolling (`CatalogLoader.itemAppeared`).
    let action: () -> Void
    var body: some View {
        Group {
            if loader.isLoading { ProgressView("正在寻找好故事…").frame(maxWidth: .infinity).padding(20) }
            else if let error = loader.error { FailureView(message: error, retry: action) }
            else if loader.hasMore { ProgressView().frame(maxWidth: .infinity).padding(20) }
            else if !loader.dramas.isEmpty { Text("已经看到最后一部了").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20) }
        }
    }
}

struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(selected ? model.appearance.accent : model.appearance.muted)
                .padding(.horizontal, 15).frame(minHeight: 42)
                .background(selected ? model.appearance.accent.opacity(0.1) : model.appearance.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? model.appearance.accent.opacity(0.35) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .firstTextBaseline) { Text(title).font(.title3.bold()).foregroundStyle(model.appearance.ink); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(model.appearance.muted) }; Spacer() }
    }
}

/// Compact in-content title row for tab roots, which hide the system navigation bar (its large title left a tall empty band).
struct TabHeader<Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) { Text(title).font(.largeTitle.bold()).foregroundStyle(model.appearance.ink).accessibilityAddTraits(.isHeader); Spacer(minLength: 0); trailing }
    }
}
extension TabHeader where Trailing == EmptyView { init(title: String) { self.init(title: title) { EmptyView() } } }

struct HeaderIcon: View {
    @EnvironmentObject private var model: AppModel
    let symbol: String
    var body: some View {
        AppControlIcon(name: symbol)
            .foregroundStyle(model.appearance.accent)
            .background { Circle().fill(model.appearance.surface).padding(2) }
    }
}

extension View {
    func appBackground(_ theme: ThemeColors) -> some View { self.background(theme.background.ignoresSafeArea()).toolbarBackground(theme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar) }
    /// Pages pushed from 我的 (settings, account) cover the tab bar, like Android's full-screen settings.
    func secondaryPage() -> some View {
        background(NavigationTabBar(hidden: true)).background(InteractiveBackSwipe(enabled: true))
    }
    /// Tab roots draw their own header; a zero-height inset keeps scrolled content from showing under the status bar.
    func tabRoot(_ theme: ThemeColors) -> some View {
        self.toolbar(.hidden, for: .navigationBar).safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 0).background(theme.background) }
    }
}
