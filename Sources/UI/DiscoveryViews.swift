import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountService.shared
    @StateObject private var loader = CatalogLoader(
        initialCacheKey: AccountService.shared.guessFeedAccess.historyKey.map { "home.guess." + $0 }
    )
    @State private var feed = "guess"
    @State private var guessPager: GuessPager?
    @State private var playbackRequest: PlaybackRequest?
    @Environment(\.scenePhase) private var scenePhase
    /// 刷剧: the full-screen feed of the same list in the card layouts, kept across launches.
    @AppStorage("home.feedMode") private var feedMode = false
    private let feeds = [("guess", "推荐"), ("recommend", "热度精选"), ("latest", "最新短剧"), ("comic", "漫剧榜单")]
    private var gridDramas: [Drama] {
        let featuredCount = model.theme == .warm ? 1 : model.theme == .cards ? 3 : 0
        return Array(loader.dramas.dropFirst(featuredCount))
    }

    var body: some View {
        Group {
            if model.appearance == .immersive || feedMode {
                ImmersiveFeed(loader: loader, feed: $feed, feeds: [("guess", "推荐"), ("recommend", "热度"), ("latest", "最新"), ("comic", "漫剧")],
                              loadMore: { load() }, refresh: refresh, canRefresh: canRequestFeed,
                              exit: model.appearance == .immersive ? nil : { feedMode = false }).toolbar(.hidden, for: .navigationBar)
            } else {
                classicHome.appBackground(model.appearance).tabRoot(model.appearance)
                    .onAppear { loader.anchorID = nil; loader.setCoverPrefetchEnabled(true) }
                    .playbackDestination($playbackRequest)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { revalidate() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { revalidate() } }
        .onChange(of: feed) { _, _ in start() }
        // Login, logout or switching account changes whose feed 猜你喜欢 shows.
        .onChange(of: account.guessFeedAccess) { _, _ in if feed == "guess" { revalidate() } }
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
                }
                SearchEntry()
                if let first = loader.dramas.first, model.appearance == .warm { featured(first) }
                if !library.history.isEmpty { continueWatching }
                feedSelector
                if model.appearance == .cards && !loader.dramas.isEmpty { ranking }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.appearance == .warm ? 104 : 145), spacing: 12)], alignment: .leading, spacing: 20) {
                    ForEach(gridDramas) { drama in NavigationLink { DetailView(drama: drama) } label: { DramaPoster(drama: drama) }.buttonStyle(.plain).accessibilityIdentifier("home.grid.\(drama.id)").onAppear { loader.itemAppeared(drama) { load() } } }
                }
                if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil {
                    EmptyStateView(symbol: "sparkles.tv", title: canRequestFeed ? "这一页暂时没有剧集" : "账号待验证",
                                   message: canRequestFeed ? "可以刷新，或切换上方的内容类型。" : "账号验证后可加载推荐，也可先浏览其他分类。")
                }
                if canRequestFeed { LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) } }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await refresh() }
        .overlay(alignment: .top) { CatalogRefreshError(message: loader.refreshError) }
    }

    private var feedSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) { ForEach(feeds, id: \.0) { value, name in ChoiceChip(title: name, selected: feed == value) { feed = value } } }
        }
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
            Button { model.play(drama) { playbackRequest = $0 } } label: {
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
                        LibraryDramaCard(drama: entry.drama, onResolved: library.updateDramaMetadata) { drama in
                            Button { model.play(drama) { playbackRequest = $0 } } label: {
                                HStack(spacing: 11) {
                                    PosterView(drama: drama, ratio: 0.8).frame(width: 57)
                                    VStack(alignment: .leading, spacing: 7) { Text(drama.title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink).lineLimit(2); Text("第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))").font(.caption).foregroundStyle(model.appearance.muted); Label("接着看", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(12).frame(width: 264).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
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

    private var cacheKey: String? {
        if feed != "guess" { return "home." + feed }
        return account.guessFeedAccess.historyKey.map { "home.guess." + $0 }
    }

    private var canRequestFeed: Bool { feed != "guess" || account.guessFeedAccess.canRequest }

    private func revalidate() {
        if loader.cacheKey != cacheKey { start() }
        else if !canRequestFeed { if loader.isLoading { loader.cancel() } }
        else if loader.needsRevalidation { load(inPlace: true) }
    }

    private func start() {
        switch loader.restore(key: cacheKey) {
        case .fresh: break
        case .stale: load(inPlace: true)
        case .none: load(reset: true)
        }
    }

    private func refresh() async {
        guard canRequestFeed else { return }
        if loader.cacheKey != cacheKey { loader.restore(key: cacheKey) }
        await load(inPlace: true, refreshing: true)?.value
    }

    @discardableResult
    private func load(reset: Bool = false, inPlace: Bool = false, refreshing: Bool = false) -> Task<Void, Never>? {
        guard canRequestFeed, loader.cacheKey == cacheKey else { return nil }
        if let pending = loader.pendingRefresh, refreshing { return pending }
        let selected = feed
        guard selected == "guess" else {
            let cachedPrefix = loader.restoredSnapshot?.dramas
            return loader.load(reset: reset, inPlace: inPlace, refreshing: refreshing) {
                try await DramaAPI.shared.home(feed: selected, offset: $0, cachedPrefix: cachedPrefix)
            }
        }
        let access = account.guessFeedAccess
        guard let historyKey = access.historyKey else { return nil }
        let owner = access.owner
        let pager: GuessPager
        if !reset, !inPlace, let guessPager, guessPager.owner == owner {
            pager = guessPager
        } else {
            pager = GuessPager(owner: owner, previous: guessPager, history: .shared, historyKey: historyKey) {
                try await AccountService.shared.guessBatch(owner: owner, cursor: $0)
            }
        }
        return loader.load(reset: reset, inPlace: inPlace, refreshing: refreshing) { offset in
            let page = try await pager.next()
            try Task.checkCancellation()
            guard account.guessFeedAccess == access else { throw CancellationError() }
            guessPager = pager
            return DramaPage(dramas: page.dramas, hasMore: page.hasMore, nextOffset: offset + 1)
        }
    }
}

/// 沉浸暗场首页：一屏一部，上下滑动切换（对齐 Android ImmersiveHome）。
private struct ImmersiveFeed: View {
    @ObservedObject var loader: CatalogLoader
    @Binding var feed: String
    let feeds: [(String, String)]
    let loadMore: () -> Void
    let refresh: () async -> Void
    let canRefresh: Bool
    /// Back to the card layout, for themes whose home is not this feed.
    var exit: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var current: String?
    @State private var direction = 1
    @State private var detailDrama: Drama?
    @State private var playbackRequest: PlaybackRequest?
    @State private var commentsVisible = false
    @AppStorage(PortraitVideoPosition.key) private var portraitVideoPosition: PortraitVideoPosition = .center
    @StateObject private var preview = FeedPreview()
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let canvas = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                                height: outer.size.height + insets.top + insets.bottom)
            let layout = PlaybackPictureLayout(canvas: canvas, insets: insets, position: portraitVideoPosition, context: .feed)
            ZStack(alignment: .top) {
                Color.black
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if loader.dramas.isEmpty {
                            placeholder.frame(width: outer.size.width, height: outer.size.height + insets.top + insets.bottom)
                        } else {
                            ForEach(Array(loader.dramas.enumerated()), id: \.element.id) { index, drama in
                                ImmersivePage(drama: drama, index: index, layout: layout, preview: preview,
                                              openDetails: { detailDrama = drama }, openComments: { commentsVisible = true },
                                              presentPlayback: presentPlayback,
                                              retryPreview: { if preview.dramaID == drama.id { syncPreview() } })
                                    .frame(width: canvas.width, height: canvas.height)
                                    .id(drama.id)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .background {
                        FeedNavigationSwipe(canNavigate: canNavigate) { direction in
                            guard canNavigate(direction) else { return }
                            if direction == .left { detailDrama = loader.dramas[index] }
                            else { exit?() }
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.hidden)
                // Anchored at the top so folding or unfolding iPhone Duo keeps the current page whole after the resize.
                .scrollPosition(id: $current, anchor: .top)
                .feedScrollActivity { moving in
                    preview.setScrolling(moving)
                    if !moving { syncPreview(); if preview.ended { continueAfterPreview() } }
                }
                .refreshable { await refresh() }
                .ignoresSafeArea()
                .accessibilityIdentifier("immersive_feed")
                if isLast, let banner, loader.refreshError == nil { endBanner(banner).padding(.top, insets.top + 64) }
                // Side insets too: the iPhone Duo cover screen puts the status bar and camera along the trailing edge.
                VStack(spacing: 4) {
                    topBar
                    CatalogRefreshError(message: loader.refreshError, overVideo: true)
                }.padding(.top, insets.top).padding(.leading, insets.leading).padding(.trailing, insets.trailing)
            }.ignoresSafeArea()
            .episodeDiscussion(preview.detail.flatMap { detail in
                detail.episodes.first.map { DiscussionEpisode(seriesID: detail.drama.id, episodeID: $0.id, number: $0.index) }
            }, player: preview.player,
               foreground: visible && scenePhase == .active && model.playback == nil && detailDrama == nil,
               hideDanmaku: preview.isScrolling || (current != nil && preview.dramaID != current),
               danmakuInsets: layout.danmakuInsets(around: layout.portraitWideFrame(for: preview.videoSize)),
               presented: $commentsVisible)
        }
        .navigationDestination(item: $detailDrama) { DetailView(drama: $0) }
        .playbackDestination($playbackRequest)
        .onChange(of: commentsVisible) { _, shown in if !shown && preview.ended { continueAfterPreview() } }
        .onChange(of: current) { old, id in
            guard let id else { return }
            if let old, let before = loader.dramas.firstIndex(where: { $0.id == old }),
               let after = loader.dramas.firstIndex(where: { $0.id == id }) { direction = after < before ? -1 : 1 }
            loader.anchorID = id
            syncPreview()
        }
        // Not swiping on: when episode 1 ends, the drama continues with episode 2 in the full player.
        .onChange(of: preview.ended) { _, ended in if ended { continueAfterPreview() } }
        .onChange(of: loader.dramas.first?.id) { _, id in direction = 1; current = id; syncPreview() }
        .onChange(of: loader.dramas.count) { _, _ in syncPreview() }
        .onChange(of: model.speed) { _, _ in syncPreview() }
        .onChange(of: model.quality) { _, _ in syncPreview() }
        // Only the visible, foreground feed plays: pushing a page, switching tab, opening the full player or
        // backgrounding releases the preview, and coming back starts the current page again.
        .onAppear { loader.setCoverPrefetchEnabled(false); visible = true; model.feedOnScreen = true; syncPreview() }
        .onDisappear { visible = false; model.feedOnScreen = false; model.refreshSystemAppearance(); preview.stop() }
        .onChange(of: model.playback == nil) { _, _ in syncPreview() }
        .onChange(of: detailDrama?.id) { _, _ in syncPreview() }
        .onChange(of: playbackRequest == nil) { _, _ in syncPreview() }
        .onChange(of: scenePhase) { _, _ in syncPreview() }
    }

    private func syncPreview() {
        guard visible, detailDrama == nil, playbackRequest == nil, scenePhase == .active, model.playback == nil,
              loader.dramas.indices.contains(index) else { preview.stop(); return }
        let index = self.index
        let neighbors = [direction, direction * 2, -direction].compactMap { step in
            loader.dramas.indices.contains(index + step) ? loader.dramas[index + step] : nil
        }
        let debounce: Bool
        if #available(iOS 18, *) { debounce = false } else { debounce = true }
        preview.select(loader.dramas[index], quality: model.quality, speed: model.speed, following: neighbors, debounce: debounce)
        if !preview.isScrolling { prefetch() }
    }

    private func continueAfterPreview() {
        guard visible, !commentsVisible, detailDrama == nil, playbackRequest == nil, model.playback == nil, model.autoNext,
              !preview.isScrolling, loader.dramas.indices.contains(index),
              let detail = preview.detail, loader.dramas[index].id == detail.drama.id else { return }
        if detail.episodes.count > 1 {
            if let request = preview.handoff(index: 1) { presentPlayback(request) }
        } else if loader.dramas.indices.contains(index + 1) {
            withAnimation(.easeInOut(duration: 0.3)) { current = loader.dramas[index + 1].id }
        }
    }

    private func presentPlayback(_ request: PlaybackRequest) {
        guard visible, detailDrama == nil, playbackRequest == nil else { return }
        playbackRequest = request
    }

    private var index: Int { current.flatMap { id in loader.dramas.firstIndex { $0.id == id } } ?? 0 }
    private var isLast: Bool { index >= loader.dramas.count - 1 }

    private func canNavigate(_ direction: HorizontalSwipeDirection) -> Bool {
        visible && scenePhase == .active && model.playback == nil && playbackRequest == nil && detailDrama == nil && !commentsVisible
            && !preview.holding && (direction == .left ? loader.dramas.indices.contains(index) : exit != nil)
    }

    private func prefetch() {
        if index >= loader.dramas.count - 3 && loader.hasMore && loader.error == nil && !loader.isLoading { loadMore() }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            ZStack {
                if let exit {
                    Button(action: exit) { AppControlIcon(name: "square.grid.2x2") }
                        .accessibilityLabel("返回卡片首页").accessibilityIdentifier("immersive_exit")
                }
            }.frame(width: 44, height: 44)
            GeometryReader { region in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(feeds, id: \.0) { value, name in
                            let selected = feed == value
                            Button { feed = value } label: {
                                Text(name).font(.system(size: selected ? 17 : 16, weight: selected ? .bold : .medium))
                                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7)).fixedSize()
                                    .frame(minWidth: 44, minHeight: 44)
                                    .overlay(alignment: .bottom) {
                                        if selected { Capsule().fill(.white).frame(width: 18, height: 3).padding(.bottom, 2) }
                                    }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.frame(minWidth: region.size.width)
                }
            }.frame(height: 44)
            NavigationLink { SearchView() } label: { AppControlIcon(name: "magnifyingglass") }
                .frame(width: 44, height: 44)
                .accessibilityLabel("搜索")
        }.foregroundStyle(.white).padding(.horizontal, 8).padding(.top, 2)
            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
    }

    @ViewBuilder private var placeholder: some View {
        if loader.isLoading {
            HStack(spacing: 12) { ProgressView().tint(.white); Text("正在准备推荐…").font(.subheadline).foregroundStyle(.white.opacity(0.8)) }
        } else {
            VStack(spacing: 12) {
                Text(canRefresh ? loader.error ?? "这一组暂时没有剧集" : "账号验证后可加载推荐")
                    .font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                if canRefresh {
                    Button("重新加载") { Task { await refresh() } }.buttonStyle(.bordered).tint(.white)
                }
            }.padding(24)
        }
    }

    private var banner: (String, String?, () -> Void)? {
        if loader.dramas.isEmpty || loader.isRefreshing { return nil }
        if let error = loader.error { return (error, "重试", loadMore) }
        if loader.isLoading { return ("正在加载更多…", nil, {}) }
        if !loader.hasMore && canRefresh { return ("已经看到最后一部了", nil, {}) }
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

private struct CatalogRefreshButton<Icon: View>: View {
    let title: String
    let busy: Bool
    var enabled = true
    let action: () async -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button { Task { await action() } } label: {
            icon().opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().tint(.primary) } }
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
        .accessibilityLabel(title)
        .accessibilityValue(busy ? "正在刷新" : "")
    }
}

private struct CatalogRefreshError: View {
    @EnvironmentObject private var model: AppModel
    let message: String?
    var overVideo = false

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(overVideo ? .white : model.appearance.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(overVideo ? .black.opacity(0.8) : model.appearance.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private extension View {
    @ViewBuilder func feedScrollActivity(_ changed: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollPhaseChange { _, phase in
                if phase != .tracking { changed(phase != .idle) }
            }
        } else { self }
    }
}

private struct ImmersivePage: View {
    let drama: Drama
    let index: Int
    let layout: PlaybackPictureLayout
    @ObservedObject var preview: FeedPreview
    let openDetails: () -> Void
    let openComments: () -> Void
    let presentPlayback: (PlaybackRequest) -> Void
    let retryPreview: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    private var insets: EdgeInsets { layout.insets }
    private var roomy: Bool { layout.canvas.height >= 640 }

    var body: some View {
        let frame = active && preview.rendered ? nil : preview.firstFrame(for: drama, quality: model.quality)
        let videoSize = active && preview.videoSize != .zero ? preview.videoSize : frame?.size ?? .zero
        let picture = layout.portraitWideFrame(for: videoSize)
        let dockInteractions = layout.overlapsInteractionColumn(picture)
        let pictureCenter = CGPoint(x: picture?.midX ?? layout.canvas.width / 2,
                                    y: picture?.midY ?? layout.canvas.height / 2)
        ZStack(alignment: .bottomLeading) {
            Color.black.task(id: PlaybackTarget(drama, quality: model.quality).key) {
                await preview.restoreFirstFrame(for: drama, quality: model.quality)
            }
            if let frame {
                VideoFrameView(image: frame).playbackPictureFrame(layout.frame(for: frame.size))
            }
            if active, let player = preview.player {
                PlayerLayerView(player: player) { host in preview.markRendered(player, host: host) }
                    .playbackPictureFrame(layout.frame(for: videoSize))
                    .opacity(preview.rendered ? 1 : 0)
            }
            if active && preview.failed {
                FeedGestureView(tap: retryPreview).overlay {
                    Label("重试播放", systemImage: "arrow.clockwise").foregroundStyle(.white)
                        .position(pictureCenter)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            } else if active, let player = preview.player {
                FeedGestureView(preview: preview, player: player, picture: picture, statusTopInset: insets.top + 64,
                                statusTrailingInset: insets.trailing + 20, restoredSpeed: String(format: "%g×", model.speed))
                    .id(ObjectIdentifier(player))
            }
            if active && preview.paused && !preview.ended {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.8))
                    .position(pictureCenter).allowsHitTesting(false)
            }
            if picture == nil {
                GeometryReader { page in
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(180, page.size.height * 0.32))
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(380, page.size.height * 0.68))
                    }
                }.allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        titleButton
                        if roomy && !drama.summary.isEmpty {
                            Text(drama.summary).font(.footnote).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    let spacing: CGFloat = dockInteractions ? 8 : layout.context.interactionSpacing
                    let actions = dockInteractions ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
                    actions {
                        favoriteButton
                        if activeDetail != nil { DiscussionControls(vertical: !dockInteractions, spacing: spacing, showComments: openComments) }
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
                    Text(drama.title).font(.playbackHeading).lineLimit(2)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
                Text(currentEpisode).font(.playbackHeading).foregroundStyle(.white.opacity(0.85))
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
        FollowDramaButton(seriesID: drama.id, selected: library.isFavorite(drama)) {
            library.toggleFavorite(drama)
        }
        .accessibilityIdentifier("immersive_favorite_\(index)")
    }

    private func playFull() {
        let continuing = continueEpisode != nil
        if active, !preview.failed, continuing || !preview.ended {
            preview.requestHandoff(index: continuing ? 1 : 0, present: presentPlayback)
        } else if continuing, let detail = preview.detail {
            model.play(detail, index: 1, present: presentPlayback)
        } else {
            model.play(drama, present: presentPlayback)
        }
    }
}

private struct FeedNavigationSwipe: UIViewRepresentable {
    let canNavigate: (HorizontalSwipeDirection) -> Bool
    let navigate: (HorizontalSwipeDirection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AttachmentView {
        AttachmentView(pan: context.coordinator.pan)
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.canNavigate = canNavigate
        context.coordinator.navigate = navigate
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
        var canNavigate: ((HorizontalSwipeDirection) -> Bool)?
        var navigate: ((HorizontalSwipeDirection) -> Void)?
        private var direction: HorizontalSwipeDirection?
        lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scrollView = gestureRecognizer.view as? UIScrollView, !scrollView.isDecelerating,
                  let direction = HorizontalSwipeDirection(movement: pan.velocity(in: scrollView)),
                  canNavigate?(direction) == true else { return false }
            self.direction = direction
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer.view as? UIScrollView)?.panGestureRecognizer === other
        }

        @objc private func didPan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let direction, direction.completes(pan.translation(in: pan.view)) else { return }
            navigate?(direction)
        }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var loader = CatalogLoader()
    @State private var genre = "short_play"
    @State private var groups: [FilterGroup] = []
    @State private var selection: [String: String] = [:]
    @State private var draft: [String: String] = [:]
    @State private var filtersVisible = false
    @State private var filtersError: String?
    @State private var filtersLoading = false
    @State private var filtersRequestID = UUID()
    /// The genre whose list and filters are loaded; coming back from a detail page keeps them as they were.
    @State private var loadedGenre: String?
    private let genres = [("short_play", "短剧"), ("comic_series", "漫剧"), ("ai_series", "AI 剧")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabHeader(title: model.appearance == .immersive ? "剧场" : "发现") {
                    CatalogRefreshButton(title: "刷新发现", busy: loader.isRefreshing, action: refresh) {
                        HeaderIcon(symbol: "arrow.clockwise")
                    }
                }
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
        }
            .scrollBounceBehavior(.always, axes: .vertical)
            .refreshable { await refresh() }
            .overlay(alignment: .top) { CatalogRefreshError(message: loader.refreshError) }
            .navigationTitle(model.appearance == .immersive ? "剧场" : "发现")
            .appBackground(model.appearance).tabRoot(model.appearance)
            .task(id: genre) {
                if loadedGenre != genre {
                    loadedGenre = genre; selection = [:]; draft = [:]; groups = []; start(); await loadFilters()
                } else {
                    revalidate()
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { revalidate() } }
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
            }.scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await loadFilters(forceRefresh: true) }
                .appBackground(model.appearance).navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { filtersVisible = false } }
                    ToolbarItem(placement: .primaryAction) {
                        CatalogRefreshButton(title: "刷新筛选条件", busy: filtersLoading,
                                             action: { await loadFilters(forceRefresh: true) }) {
                            HeaderIcon(symbol: "arrow.clockwise")
                        }
                    }
                }
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
    private func revalidate() {
        if loadedGenre == genre && selection.isEmpty && loader.needsRevalidation { load(inPlace: true) }
    }
    private func refresh() async { await load(inPlace: true, refreshing: true)?.value }

    @discardableResult
    private func load(reset: Bool = false, inPlace: Bool = false, refreshing: Bool = false) -> Task<Void, Never>? {
        let kind = genre, filters = selection
        let cachedPrefix = loader.restoredSnapshot?.dramas
        return loader.load(reset: reset, inPlace: inPlace, refreshing: refreshing) {
            try await DramaAPI.shared.browse(genre: kind, filters: filters, offset: $0, cachedPrefix: cachedPrefix)
        }
    }

    private func loadFilters(forceRefresh: Bool = false) async {
        let ticket = UUID(); filtersRequestID = ticket
        filtersLoading = true; filtersError = nil
        let selected = genre
        defer { if ticket == filtersRequestID { filtersLoading = false } }
        do {
            let result = try await DramaAPI.shared.filters(genre: selected, forceRefresh: forceRefresh)
            guard !Task.isCancelled, ticket == filtersRequestID, selected == genre else { return }
            groups = result
        } catch {
            guard !Task.isCancelled, ticket == filtersRequestID, selected == genre else { return }
            filtersError = friendlyError(error)
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CatalogLoader()
    @State private var query = ""
    @State private var submitted = ""
    @State private var suggestions: [String] = []
    @State private var didFocusOnEntry = false
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
        }.scrollBounceBehavior(.always, axes: .vertical)
            .refreshable { await refresh() }
            .overlay(alignment: .top) { CatalogRefreshError(message: loader.refreshError) }
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline).appBackground(model.appearance).onDisappear { focused = false }
            .secondaryPage()
            .toolbar {
                if !submitted.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        CatalogRefreshButton(title: "刷新搜索结果", busy: loader.isRefreshing, action: refresh) {
                            HeaderIcon(symbol: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear {
                guard !didFocusOnEntry else { return }
                didFocusOnEntry = true
                focused = true
            }
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
    private func refresh() async {
        guard !submitted.isEmpty else { return }
        await load(refreshing: true)?.value
    }

    @discardableResult
    private func load(reset: Bool = false, refreshing: Bool = false) -> Task<Void, Never>? {
        let value = submitted
        return loader.load(reset: reset, inPlace: refreshing, refreshing: refreshing) {
            try await DramaAPI.shared.search(query: value, offset: $0, forceRefresh: refreshing)
        }
    }
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
