import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountService.shared
    @StateObject private var loader = CatalogLoader()
    @State private var feed = "guess"
    @State private var guessPager: GuessPager?
    /// 刷剧: the full-screen feed of the same list in the card layouts, kept across launches.
    @AppStorage("home.feedMode") private var feedMode = false
    // 推荐 is the default channel and sits at the far right; the row opens scrolled to it.
    private let feeds = [("recommend", "热度精选"), ("latest", "最新短剧"), ("comic", "漫剧榜单"), ("guess", "推荐")]
    private var gridDramas: [Drama] {
        let featuredCount = model.theme == .warm ? 1 : model.theme == .cards ? 3 : 0
        return Array(loader.dramas.dropFirst(featuredCount))
    }

    var body: some View {
        Group {
            if model.appearance == .immersive || feedMode {
                ImmersiveFeed(loader: loader, feed: $feed, feeds: [("recommend", "热度"), ("latest", "最新"), ("comic", "漫剧"), ("guess", "推荐")],
                              load: { more in if more { load() } else { refresh() } },
                              exit: model.appearance == .immersive ? nil : { feedMode = false }).toolbar(.hidden, for: .navigationBar)
            } else {
                classicHome.appBackground(model.appearance).tabRoot(model.appearance)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { if loader.dramas.isEmpty && !loader.isLoading { start() } }
        .onChange(of: feed) { _, _ in start() }
        // Login, logout or switching account changes whose feed 猜你喜欢 shows.
        .onChange(of: account.guessOwner) { _, _ in if feed == "guess" { start() } }
    }

    private var refreshButton: some View {
        Button { refresh() } label: { HeaderIcon(symbol: "arrow.clockwise") }.buttonStyle(.plain).accessibilityLabel("刷新首页")
    }

    private var feedModeButton: some View {
        Button { feedMode = true } label: { HeaderIcon(symbol: "play.rectangle.on.rectangle") }.buttonStyle(.plain)
            .accessibilityLabel("全屏刷剧").accessibilityIdentifier("home.feedMode")
    }

    private var classicHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 40, height: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) { Text("红果剧场").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("好故事，随时接着看").font(.caption).foregroundStyle(model.appearance.muted) }
                    Spacer()
                    feedModeButton
                    refreshButton
                }
                SearchEntry()
                if let first = loader.dramas.first, model.appearance == .warm { featured(first) }
                if !library.history.isEmpty { continueWatching }
                feedSelector
                if model.appearance == .cards && !loader.dramas.isEmpty { ranking }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.appearance == .warm ? 104 : 145), spacing: 12)], alignment: .leading, spacing: 20) {
                    ForEach(gridDramas) { drama in NavigationLink { DetailView(drama: drama) } label: { DramaPoster(drama: drama) }.buttonStyle(.plain).accessibilityIdentifier("home.grid.\(drama.id)").onAppear { loader.itemAppeared(drama) { load() } } }
                }
                if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "sparkles.tv", title: "这一页暂时没有剧集", message: "可以刷新，或切换上方的内容类型。") }
                LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }.refreshable { refresh() }
    }

    private var feedSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) { ForEach(feeds, id: \.0) { value, name in ChoiceChip(title: name, selected: feed == value) { feed = value } } }
        }.defaultScrollAnchor(.trailing)
    }

    /// The card opens the detail page and 立即播放 plays; the two are siblings so neither swallows the other's taps,
    /// and the cover cannot reach past the card (it used to cover the search bar above).
    private func featured(_ drama: Drama) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        return ZStack(alignment: .bottomTrailing) {
            NavigationLink { DetailView(drama: drama) } label: {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(address: drama.coverURL, priority: .high) { model.appearance.soft }
                    LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("今日推荐").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                        Text(drama.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                        Text(drama.episodeCount > 0 ? "全 \(drama.episodeCount) 集" : "精彩短剧").font(.caption).foregroundStyle(.white.opacity(0.8))
                    }.padding(18).padding(.trailing, 110)
                }.frame(height: 210).frame(maxWidth: .infinity).clipShape(shape).contentShape(shape)
            }.buttonStyle(.plain).accessibilityIdentifier("home.featured.\(drama.id)")
            Button { model.play(drama) } label: {
                Label("立即播放", systemImage: "play.fill").font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 10)
                    .background(.white, in: Capsule()).foregroundStyle(Color(hex: 0xA9341F))
            }.buttonStyle(.plain).padding(18).accessibilityIdentifier("home.featured.play")
        }.frame(height: 210).clipShape(shape)
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { SectionHeading(title: "继续观看", subtitle: "本机"); NavigationLink("全部") { PlayHistoryView(startLocal: true) }.font(.caption).foregroundStyle(model.appearance.muted) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(library.history.prefix(8))) { entry in
                        Button { model.play(entry.drama) } label: {
                            HStack(spacing: 11) {
                                PosterView(drama: entry.drama, ratio: 0.8).frame(width: 57)
                                VStack(alignment: .leading, spacing: 7) { Text(entry.drama.title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink).lineLimit(2); Text("第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))").font(.caption).foregroundStyle(model.appearance.muted); Label("接着看", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).frame(width: 264).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeading(title: feed == "guess" ? "为你推荐" : "热度榜", subtitle: feed == "guess" ? "猜你喜欢" : "大家都在追")
            ForEach(Array(loader.dramas.prefix(3).enumerated()), id: \.element.id) { index, drama in
                NavigationLink { DetailView(drama: drama) } label: { HStack(spacing: 12) { Text("\(index + 1)").font(.title2.bold().italic()).foregroundStyle(model.appearance.accent).frame(width: 24); Text(drama.title).font(.subheadline.weight(.medium)).foregroundStyle(model.appearance.ink).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(model.appearance.muted) }.frame(minHeight: 38).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("home.ranking.\(drama.id)")
            }
        }.padding(16).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    /// The saved copy of this feed shows at once; it is refreshed behind it when older than half an hour.
    private func start() {
        let key = feed == "guess" ? "home.guess." + account.guessHistoryKey : "home." + feed
        switch loader.restore(key: key) {
        case .fresh: break
        case .stale: load(inPlace: true)
        case .none: load(reset: true)
        }
    }

    /// Refresh keeps what is on screen until the new first page arrives.
    private func refresh() { if loader.dramas.isEmpty { load(reset: true) } else { load(inPlace: true) } }

    private func load(reset: Bool = false, inPlace: Bool = false) {
        let selected = feed
        guard selected == "guess" else { loader.load(reset: reset, inPlace: inPlace) { try await DramaAPI.shared.home(feed: selected, offset: $0) }; return }
        // Signed in: the account's own feed; otherwise the anonymous one. A changed owner restarts the round. A list
        // restored from disk has no round yet: the next page starts one and adds to the list.
        let owner = account.guessOwner
        let restart = reset || inPlace || guessPager == nil || guessPager?.owner != owner
        if restart { guessPager = GuessPager(owner: owner, previous: guessPager, history: .shared, historyKey: account.guessHistoryKey) { cursor in try await AccountService.shared.guessBatch(owner: owner, cursor: cursor) } }
        guard let pager = guessPager else { return }
        loader.load(reset: reset, inPlace: inPlace) { _ in try await pager.next() }
    }
}

/// 沉浸暗场首页：一屏一部，上下滑动切换（对齐 Android ImmersiveHome）。
private struct ImmersiveFeed: View {
    @ObservedObject var loader: CatalogLoader
    @Binding var feed: String
    let feeds: [(String, String)]
    /// true for the next page, false to refresh.
    let load: (Bool) -> Void
    /// Back to the card layout, for themes whose home is not this feed.
    var exit: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var current: String?
    @State private var detailDrama: Drama?
    @State private var commentsVisible = false
    @StateObject private var preview = FeedPreview()
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            ZStack(alignment: .top) {
                Color.black
                if loader.dramas.isEmpty {
                    placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(loader.dramas.enumerated()), id: \.element.id) { index, drama in
                                ImmersivePage(drama: drama, index: index, insets: insets,
                                              roomy: outer.size.height + insets.top + insets.bottom >= 640, preview: preview,
                                              openDetails: { detailDrama = drama }, openComments: { commentsVisible = true },
                                              retryPreview: { if preview.dramaID == drama.id { syncPreview() } })
                                    .frame(width: outer.size.width + insets.leading + insets.trailing,
                                           height: outer.size.height + insets.top + insets.bottom)
                                    .id(drama.id)
                            }
                        }
                        .scrollTargetLayout()
                        .background {
                            FeedDetailSwipe(canBegin: { !preview.holding }) {
                                if loader.dramas.indices.contains(index) { detailDrama = loader.dramas[index] }
                            }
                        }
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    // Anchored at the top so folding or unfolding iPhone Duo keeps the current page whole after the resize.
                    .scrollPosition(id: $current, anchor: .top)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("immersive_feed")
                    if isLast, let banner { endBanner(banner).padding(.top, insets.top + 64) }
                }
                // Side insets too: the iPhone Duo cover screen puts the status bar and camera along the trailing edge.
                topBar.padding(.top, insets.top).padding(.leading, insets.leading).padding(.trailing, insets.trailing)
            }.ignoresSafeArea()
        }
        .navigationDestination(item: $detailDrama) { DetailView(drama: $0) }
        .episodeDiscussion(preview.detail.flatMap { detail in
            detail.episodes.first.map { DiscussionEpisode(seriesID: detail.drama.id, episodeID: $0.id, number: $0.index) }
        }, player: preview.player, playing: preview.rendered && !preview.paused && !preview.ended,
           foreground: visible && scenePhase == .active && model.playback == nil && detailDrama == nil,
           presented: $commentsVisible)
        .onChange(of: commentsVisible) { _, shown in if !shown && preview.ended { continueAfterPreview() } }
        .onChange(of: current) { _, id in loader.anchorID = id; prefetch(); syncPreview() }
        // Not swiping on: when episode 1 ends, the drama continues with episode 2 in the full player.
        .onChange(of: preview.ended) { _, ended in if ended { continueAfterPreview() } }
        .onChange(of: loader.dramas.first?.id) { _, _ in current = loader.dramas.first?.id; syncPreview() }
        .onChange(of: loader.dramas.count) { _, _ in syncPreview() }
        .onChange(of: model.speed) { _, _ in syncPreview() }
        .onChange(of: model.quality) { _, _ in syncPreview() }
        // Only the visible, foreground feed plays: pushing a page, switching tab, opening the full player or
        // backgrounding releases the preview, and coming back starts the current page again.
        .onAppear { visible = true; model.feedOnScreen = true; syncPreview() }
        .onDisappear { visible = false; model.feedOnScreen = false; model.refreshSystemAppearance(); preview.stop() }
        .onChange(of: model.playback == nil) { _, _ in syncPreview() }
        .onChange(of: scenePhase) { _, _ in syncPreview() }
    }

    private func syncPreview() {
        guard visible, detailDrama == nil, scenePhase == .active, model.playback == nil, loader.dramas.indices.contains(index) else { preview.stop(); return }
        let index = self.index
        preview.play(loader.dramas[index], quality: model.quality, speed: model.speed,
                     following: Array(loader.dramas.dropFirst(index + 1).prefix(2)))
    }

    private func continueAfterPreview() {
        guard visible, !commentsVisible, detailDrama == nil, model.playback == nil, model.autoNext,
              let detail = preview.detail, preview.dramaID == detail.drama.id else { return }
        if detail.episodes.count > 1 {
            if let request = preview.handoff(index: 1) { model.presentFeedPlayback(request) }
        } else if loader.dramas.indices.contains(index + 1) {
            withAnimation(.easeInOut(duration: 0.3)) { current = loader.dramas[index + 1].id }
        }
    }

    private var index: Int { current.flatMap { id in loader.dramas.firstIndex { $0.id == id } } ?? 0 }
    private var isLast: Bool { index >= loader.dramas.count - 1 }

    private func prefetch() {
        if loader.dramas.indices.contains(index) { loader.preloadCovers(after: loader.dramas[index]) }
        if index >= loader.dramas.count - 3 && loader.hasMore && loader.error == nil && !loader.isLoading { load(true) }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            if let exit {
                Button(action: exit) { Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("返回卡片首页").accessibilityIdentifier("immersive_exit")
            }
            Button { load(false) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("刷新推荐")
            HStack(spacing: 16) {
                ForEach(feeds, id: \.0) { value, name in
                    let selected = feed == value
                    Button { feed = value } label: {
                        VStack(spacing: 4) {
                            Text(name).font(.system(size: selected ? 17 : 16, weight: selected ? .bold : .medium))
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.7)).fixedSize()
                            Capsule().fill(selected ? Color.white : .clear).frame(width: 18, height: 3)
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.frame(maxWidth: .infinity)
            NavigationLink { SearchView() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("搜索")
        }.foregroundStyle(.white).padding(.horizontal, 8).padding(.top, 2)
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
    }

    @ViewBuilder private var placeholder: some View {
        if loader.isLoading {
            HStack(spacing: 12) { ProgressView().tint(.white); Text("正在准备推荐…").font(.subheadline).foregroundStyle(.white.opacity(0.8)) }
        } else {
            VStack(spacing: 12) {
                Text(loader.error ?? "这一组暂时没有剧集").font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("重新加载") { load(false) }.buttonStyle(.bordered).tint(.white)
            }.padding(24)
        }
    }

    private var banner: (String, String?, () -> Void)? {
        if let error = loader.error { return (error, "重试", { load(true) }) }
        if loader.isLoading { return ("正在加载更多…", nil, {}) }
        if !loader.hasMore { return ("已经看到最后一部了", "刷新", { load(false) }) }
        return nil
    }

    private func endBanner(_ banner: (String, String?, () -> Void)) -> some View {
        HStack(spacing: 4) {
            Text(banner.0).font(.footnote).foregroundStyle(.white).lineLimit(2).padding(.vertical, 8)
            if let action = banner.1 { Button(action, action: banner.2).font(.footnote.weight(.semibold)).foregroundStyle(Color(hex: 0xFFC56B)) }
        }.padding(.leading, 16).padding(.trailing, banner.1 == nil ? 16 : 8).frame(minHeight: 40)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 24)
    }
}

private struct ImmersivePage: View {
    let drama: Drama
    let index: Int
    let insets: EdgeInsets
    let roomy: Bool
    @ObservedObject var preview: FeedPreview
    let openDetails: () -> Void
    let openComments: () -> Void
    let retryPreview: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.overlay {
                if !active || !preview.rendered, let frame = preview.firstFrame(for: drama, quality: model.quality) {
                    Image(uiImage: frame).resizable().scaledToFit()
                }
            }.clipped().task(id: PlaybackTarget(drama, quality: model.quality).key) {
                await preview.restoreFirstFrame(for: drama, quality: model.quality)
            }
            if active, let player = preview.player {
                PlayerLayerView(player: player) { host in preview.markRendered(player, host: host) }.opacity(preview.rendered ? 1 : 0)
            }
            if active && preview.failed {
                FeedGestureView(tap: retryPreview).overlay {
                    Label("重试播放", systemImage: "arrow.clockwise").foregroundStyle(.white)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            } else if active, let player = preview.player {
                FeedGestureView(preview: preview, player: player, statusTopInset: insets.top + 64,
                                statusTrailingInset: insets.trailing + 20, restoredSpeed: String(format: "%g×", model.speed))
                    .id(ObjectIdentifier(player))
            }
            if active && preview.paused && !preview.ended {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
            GeometryReader { page in
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(180, page.size.height * 0.32))
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(380, page.size.height * 0.68))
                }
            }.allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        titleButton
                        if roomy && !drama.summary.isEmpty {
                            Text(drama.summary).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 4) {
                        favoriteButton
                        if activeDetail != nil { DiscussionControls(vertical: true, showComments: openComments) }
                    }.shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                }
                episodeStrip
            }.padding(.leading, 16 + insets.leading).padding(.trailing, 16 + insets.trailing).padding(.bottom, 12 + insets.bottom)
        }
    }

    private var active: Bool { preview.dramaID == drama.id }
    private var activeDetail: DramaDetail? { active ? preview.detail : nil }
    private var continueEpisode: Episode? { preview.ended ? activeDetail?.episodes.dropFirst().first : nil }

    private var titleButton: some View {
        let currentEpisode = "第 \(activeDetail?.episodes.first?.index ?? 1) 集"
        return Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(drama.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
                Text(currentEpisode).font(.footnote).foregroundStyle(.white.opacity(0.74))
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(drama.title)
        .accessibilityValue(currentEpisode)
        .accessibilityHint("打开剧集详情")
        .accessibilityIdentifier("immersive_title_\(index)")
    }

    private var episodeStrip: some View {
        let episodeCount = activeDetail.map { $0.episodes.count } ?? drama.episodeCount
        let total = episodeCount > 0 ? "全 \(episodeCount) 集" : ""
        let title = continueEpisode.map { "继续播放 · 第 \($0.index) 集" } ?? "看全集"
        let strip = PlaybackEpisodeStrip(title: title, detail: total, chevron: "chevron.right")
        return Button(action: playFull) {
            if model.openingDramaID == drama.id || (active && preview.awaitingHandoff) {
                DelayedPlaybackLoading {
                    PlaybackEpisodeStrip(title: "正在打开…", detail: total, symbol: "hourglass", chevron: "chevron.right")
                } fallback: {
                    strip
                }
            } else {
                strip
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(total)
        .accessibilityHint("进入播放器，可在播放器选集")
        .accessibilityIdentifier("immersive_play_\(index)")
    }

    private var favoriteButton: some View {
        let favorite = library.isFavorite(drama)
        return Button { library.toggleFavorite(drama) } label: {
            Image(systemName: favorite ? "star.fill" : "star")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favorite ? "已追" : "追剧")
        .accessibilityHint(favorite ? "取消本机收藏" : "添加本机收藏")
        .accessibilityIdentifier("immersive_favorite_\(index)")
    }

    private func playFull() {
        let continuing = continueEpisode != nil
        if active, !preview.failed, continuing || !preview.ended {
            preview.requestHandoff(index: continuing ? 1 : 0, present: model.presentFeedPlayback)
        } else if continuing, let detail = preview.detail {
            model.play(detail, index: 1)
        } else {
            model.play(drama)
        }
    }
}

private struct FeedDetailSwipe: UIViewRepresentable {
    let canBegin: () -> Bool
    let openDetails: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AttachmentView {
        AttachmentView(pan: context.coordinator.pan)
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.canBegin = canBegin
        context.coordinator.openDetails = openDetails
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.pan.view?.removeGestureRecognizer(uiView.pan)
    }

    final class AttachmentView: UIView {
        let pan: UIPanGestureRecognizer

        init(pan: UIPanGestureRecognizer) {
            self.pan = pan
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = window == nil ? nil : superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            if pan.view !== ancestor {
                pan.view?.removeGestureRecognizer(pan)
                ancestor?.addGestureRecognizer(pan)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canBegin: (() -> Bool)?
        var openDetails: (() -> Void)?
        lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard canBegin?() == true, let scrollView = gestureRecognizer.view as? UIScrollView,
                  !scrollView.isDecelerating else { return false }
            let velocity = pan.velocity(in: scrollView)
            return velocity.x < -abs(velocity.y) * 1.35
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer.view as? UIScrollView)?.panGestureRecognizer === other
        }

        @objc private func didPan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended else { return }
            let movement = pan.translation(in: pan.view)
            if movement.x <= -56 && -movement.x > abs(movement.y) * 1.35 { openDetails?() }
        }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CatalogLoader()
    @State private var genre = "short_play"
    @State private var groups: [FilterGroup] = []
    @State private var selection: [String: String] = [:]
    @State private var draft: [String: String] = [:]
    @State private var filtersVisible = false
    @State private var filtersError: String?
    @State private var filtersLoading = false
    /// The genre whose list and filters are loaded; coming back from a detail page keeps them as they were.
    @State private var loadedGenre: String?
    private let genres = [("short_play", "短剧"), ("comic_series", "漫剧"), ("ai_series", "AI 剧")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabHeader(title: model.appearance == .immersive ? "剧场" : "发现")
                HStack(spacing: 10) {
                    SearchEntry(title: "搜索剧名或关键词")
                    NavigationLink { RankView() } label: {
                        Label("榜单", systemImage: "chart.bar.fill").font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.accent)
                            .padding(.horizontal, 12).frame(minHeight: 44).background(model.appearance.surface, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("榜单")
                }
                HStack(spacing: 10) { ForEach(genres, id: \.0) { value, name in ChoiceChip(title: name, selected: genre == value) { genre = value } }; Spacer(minLength: 0) }
                Button { draft = selection; filtersVisible = true } label: {
                    HStack(spacing: 12) { Image(systemName: "slider.horizontal.3").font(.title3); VStack(alignment: .leading, spacing: 4) { Text("筛选条件").font(.subheadline.weight(.semibold)); Text(selection.isEmpty ? "按题材、排序等条件查找" : "已应用 \(selection.count) 项条件").font(.caption).foregroundStyle(model.appearance.muted) }; Spacer(); Text("筛选").font(.subheadline.weight(.medium)); Image(systemName: "chevron.down").font(.caption) }.foregroundStyle(model.appearance.ink).padding(17).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17))
                }.buttonStyle(.plain)
                if model.appearance == .cards {
                    LazyVStack(spacing: 12) { ForEach(loader.dramas) { drama in DramaListRow(drama: drama).onAppear { loader.itemAppeared(drama) { load() } } } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.appearance == .immersive ? 100 : 140), spacing: 12)], spacing: 20) { ForEach(loader.dramas) { drama in NavigationLink { DetailView(drama: drama) } label: { DramaPoster(drama: drama) }.buttonStyle(.plain).onAppear { loader.itemAppeared(drama) { load() } } } }
                }
                if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "没有符合条件的剧集", message: "试试减少筛选条件，或切换内容类型。") }
                LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.navigationTitle(model.appearance == .immersive ? "剧场" : "发现")
            .appBackground(model.appearance).tabRoot(model.appearance)
            .refreshable { if loader.dramas.isEmpty { load(reset: true) } else { load(inPlace: true) } }
            .task(id: genre) {
                guard loadedGenre != genre else { return }
                loadedGenre = genre; selection = [:]; draft = [:]; start(); await loadFilters()
            }
            .sheet(isPresented: $filtersVisible) { filterSheet }
    }

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    if filtersLoading { ProgressView("正在读取筛选条件…") }
                    if let filtersError { FailureView(message: filtersError) { Task { await loadFilters() } } }
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.name).font(.headline).foregroundStyle(model.appearance.ink)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ChoiceChip(title: "全部", selected: draft[group.id] == nil) { draft.removeValue(forKey: group.id) }
                                    ForEach(group.options.filter { !$0.id.isEmpty }, id: \.id) { option in ChoiceChip(title: option.name, selected: draft[group.id] == option.id) { if draft[group.id] == option.id { draft.removeValue(forKey: group.id) } else { draft[group.id] = option.id } } }
                                }
                            }
                        }
                    }
                    if groups.isEmpty && !filtersLoading && filtersError == nil { Text("当前类型暂无更多筛选条件。").foregroundStyle(model.appearance.muted) }
                }.padding(20)
            }.appBackground(model.appearance).navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { filtersVisible = false } } }
                .safeAreaInset(edge: .bottom) { HStack(spacing: 12) { Button("重置") { draft = [:] }.buttonStyle(.bordered).frame(maxWidth: .infinity); Button("查看结果") { selection = draft; filtersVisible = false; start() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity) }.tint(model.appearance.accent).controlSize(.large).padding().background(model.appearance.surface) }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    /// Only the unfiltered list of a genre keeps a disk copy.
    private func start() {
        switch loader.restore(key: selection.isEmpty ? "discover." + genre : nil) {
        case .fresh: break
        case .stale: load(inPlace: true)
        case .none: load(reset: true)
        }
    }
    private func load(reset: Bool = false, inPlace: Bool = false) { let kind = genre, filters = selection; loader.load(reset: reset, inPlace: inPlace) { try await DramaAPI.shared.browse(genre: kind, filters: filters, offset: $0) } }
    private func loadFilters() async {
        filtersLoading = true; filtersError = nil
        let selected = genre
        do { let result = try await DramaAPI.shared.filters(genre: selected); guard !Task.isCancelled, selected == genre else { return }; groups = result; filtersLoading = false }
        catch { guard !Task.isCancelled, selected == genre else { return }; filtersError = friendlyError(error); groups = []; filtersLoading = false }
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CatalogLoader()
    @State private var query = ""
    @State private var submitted = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(model.appearance.muted); TextField("搜索剧名或关键词", text: $query).submitLabel(.search).focused($focused).onSubmit(submit); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(model.appearance.muted) }.accessibilityLabel("清空搜索词") } }.padding(13).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 14))
                    Button("搜索", action: submit).font(.subheadline.bold()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).buttonStyle(.borderedProminent).tint(model.appearance.accent)
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { query = suggestion; submit() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(model.appearance.muted)
                                    Text(suggestion).font(.subheadline).foregroundStyle(model.appearance.ink).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 12).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                if submitted.isEmpty { EmptyStateView(symbol: "magnifyingglass", title: "寻找你的下一部好剧", message: "输入剧名或关键词，发现喜欢的故事。") }
                else {
                    SectionHeading(title: "“\(submitted)”的结果", subtitle: "\(loader.dramas.count) 部")
                    LazyVStack(spacing: 12) { ForEach(loader.dramas) { drama in DramaListRow(drama: drama).onAppear { loader.itemAppeared(drama) { load() } } } }
                    if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "doc.text.magnifyingglass", title: "没有找到相关短剧", message: "换一个关键词再试试。") }
                    LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
                }
            }.padding(20)
        }.navigationTitle("搜索").navigationBarTitleDisplayMode(.inline).appBackground(model.appearance).onDisappear { focused = false }
            // Optional help while typing: a failure simply shows no suggestions.
            .task(id: query) {
                let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value != submitted else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let rows = (try? await DramaAPI.shared.suggestions(query: value)) ?? []
                if !Task.isCancelled { suggestions = rows }
            }
    }
    private func submit() { let value = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }; suggestions = []; focused = false; submitted = value; load(reset: true) }
    private func load(reset: Bool = false) { let value = submitted; loader.load(reset: reset) { try await DramaAPI.shared.search(query: value, offset: $0) } }
}

struct DramaListRow: View {
    let drama: Drama
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationLink { DetailView(drama: drama) } label: {
            HStack(alignment: .top, spacing: 14) {
                PosterView(drama: drama).frame(width: 88)
                VStack(alignment: .leading, spacing: 9) {
                    Text(drama.title).font(.headline).foregroundStyle(model.appearance.ink).lineLimit(2)
                    if drama.episodeCount > 0 { Text("全 \(drama.episodeCount) 集").font(.caption).foregroundStyle(model.appearance.accent) }
                    Text(drama.summary.isEmpty ? "点开查看剧集，开启一段新故事。" : drama.summary).font(.caption).foregroundStyle(model.appearance.muted).lineLimit(3)
                    Label("查看选集", systemImage: "play.circle").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain)
    }
}
