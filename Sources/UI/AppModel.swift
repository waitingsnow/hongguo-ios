import SwiftUI
import Combine
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case warm, immersive, cards
    var id: String { rawValue }
    var name: String { switch self { case .warm: return "暖白精修"; case .immersive: return "沉浸暗场"; case .cards: return "内容卡片" } }
    var subtitle: String { switch self { case .warm: return "温暖留白，轻松发现好故事"; case .immersive: return "竖屏刷剧，一屏一部好剧"; case .cards: return "榜单与卡片，丰富而有序" } }
    /// The natural mode before the user picks one: 沉浸暗场 is dark, the others light.
    var defaultDark: Bool { self == .immersive }
    func colors(dark: Bool) -> ThemeColors { ThemeColors(style: self, dark: dark) }
}

/// Whether the interface is light or dark, chosen in 设置 and independent of the layout.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}

/// A layout in one mode. Every screen reads its colors from here.
struct ThemeColors: Equatable {
    let style: AppTheme
    let dark: Bool
    var background: Color {
        switch (style, dark) {
        case (.warm, false): return Color(hex: 0xFCF8F4)
        case (.warm, true): return Color(hex: 0x1A1512)
        case (.immersive, false): return Color(hex: 0xF6F6F8)
        case (.immersive, true): return Color(hex: 0x111113)
        case (.cards, false): return Color(hex: 0xF2F3F5)
        case (.cards, true): return Color(hex: 0x0F1012)
        }
    }
    var surface: Color {
        guard dark else { return .white }
        switch style { case .warm: return Color(hex: 0x241E1A); case .immersive: return Color(hex: 0x1E1E22); case .cards: return Color(hex: 0x1A1B1F) }
    }
    var ink: Color {
        guard dark else { return style == .immersive ? Color(hex: 0x17171B) : Color(hex: 0x292421) }
        switch style { case .warm: return Color(hex: 0xF5EEE8); case .immersive: return Color(hex: 0xF8F5F0); case .cards: return Color(hex: 0xF2F3F5) }
    }
    var muted: Color {
        guard dark else { return style == .immersive ? Color(hex: 0x62626C) : Color(hex: 0x786E67) }
        switch style { case .warm: return Color(hex: 0xB8ACA3); case .immersive: return Color(hex: 0xB3ACAA); case .cards: return Color(hex: 0xA5A9B1) }
    }
    var accent: Color {
        guard dark else { return Color(hex: 0xC94426) }
        switch style { case .warm: return Color(hex: 0xFF9B7A); case .immersive: return Color(hex: 0xFF805F); case .cards: return Color(hex: 0xFF8A80) }
    }
    var soft: Color {
        guard dark else { return style == .immersive ? Color(hex: 0xFBE9E4) : Color(hex: 0xF5EDE5) }
        switch style { case .warm: return Color(hex: 0x3A241C); case .immersive: return Color(hex: 0x332421); case .cards: return Color(hex: 0x3A1C1A) }
    }
    /// Layout checks read as before: `model.appearance == .immersive`.
    static func == (colors: ThemeColors, style: AppTheme) -> Bool { colors.style == style }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

struct PlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    let detail: DramaDetail
    let index: Int
    let position: Double
    let recordsLocalHistory: Bool
    var handoff: FeedHandoff? = nil
    var sleepDeadline: ContinuousClock.Instant? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var theme: AppTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") } }
    /// nil until the user picks a mode, so each layout keeps its natural look.
    @Published var appearanceMode: AppearanceMode? { didSet { UserDefaults.standard.set(appearanceMode?.rawValue, forKey: "appearanceMode") } }
    /// The full-screen video feed (沉浸暗场's home, or 刷剧 in the other layouts) stays dark in every mode, including its status bar and tab bar.
    @Published var feedOnScreen = false
    @Published var autoNext: Bool { didSet { UserDefaults.standard.set(autoNext, forKey: "autoNext") } }
    @Published var preloadNext: Bool { didSet { UserDefaults.standard.set(preloadNext, forKey: "preloadNext") } }
    @Published var speed: Float { didSet { UserDefaults.standard.set(speed, forKey: "speed") } }
    /// 默认清晰度 for every new episode; the player's 清晰度 button changes it too, like the speed.
    @Published var quality: VideoQuality { didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") } }
    /// 官方弹幕参数；每一项单独落盘，键名与 Android 端同一语义（屏占比用千分数）。
    @Published var danmaku: DanmakuSettings { didSet { Self.storeDanmaku(danmaku) } }
    @Published var tab = 0
    @Published var systemDark = UITraitCollection.current.userInterfaceStyle == .dark
    @Published private(set) var playback: PlaybackRequest?
    func showPlayback(_ request: PlaybackRequest) { playback = request }
    func hidePlayback(_ id: UUID) {
        if playback?.id == id { playback = nil }
    }
    @Published var openingDramaID: String?
    @Published var openError: String?
    private var openTask: Task<Void, Never>?
    private var openID: UUID?
    let library = LibraryStore.shared
    var currentMode: AppearanceMode { appearanceMode ?? (theme.defaultDark ? .dark : .light) }
    private var modeDark: Bool {
        switch currentMode { case .system: return systemDark; case .light: return false; case .dark: return true }
    }
    private var feedForcesDark: Bool { feedOnScreen }
    var isDark: Bool { modeDark || feedForcesDark }
    var appearance: ThemeColors { theme.colors(dark: isDark) }
    /// Applied to the window directly: `preferredColorScheme(nil)` does not reliably return to the system after an explicit value.
    var windowStyle: UIUserInterfaceStyle { currentMode == .system && !feedForcesDark ? .unspecified : (isDark ? .dark : .light) }
    private var windowScene: UIWindowScene? { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first }
    private var systemAppearanceRegistration: (any UITraitChangeRegistration)?

    func applyWindowStyle() {
        let style = windowStyle
        windowScene?.windows.forEach { $0.overrideUserInterfaceStyle = style }
    }
    /// The scene's traits ignore the windows' override, so this always reads the real system setting.
    func refreshSystemAppearance() {
        systemDark = (windowScene?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
    }
    func startAppearanceTracking() {
        refreshSystemAppearance()
        applyWindowStyle()
        guard systemAppearanceRegistration == nil, let windowScene else { return }
        systemAppearanceRegistration = windowScene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
            self?.refreshSystemAppearance()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "warm") ?? .warm
        // The old switch 深色模式时自动切换 meant following the system.
        appearanceMode = defaults.string(forKey: "appearanceMode").flatMap(AppearanceMode.init) ?? (defaults.bool(forKey: "followSystemDark") ? .system : nil)
        defaults.register(defaults: ["autoNext": true])
        autoNext = defaults.bool(forKey: "autoNext")
        preloadNext = defaults.object(forKey: "preloadNext") as? Bool ?? false
        let saved = defaults.float(forKey: "speed")
        speed = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(saved) ? saved : 1
        quality = defaults.string(forKey: "quality").flatMap(VideoQuality.init) ?? .p1080
        danmaku = Self.loadDanmaku(defaults).normalized()
    }

    private static func loadDanmaku(_ defaults: UserDefaults) -> DanmakuSettings {
        let permille = defaults.integer(forKey: "danmaku_coverage_permille")
        return DanmakuSettings(
            enabled: defaults.object(forKey: "danmaku_enabled") as? Bool ?? true,
            coverage: permille > 0 ? DanmakuPrefs.coverageFromPermille(permille) : DanmakuPrefs.coverageDefault,
            font: DanmakuPrefs.font(defaults.integer(forKey: "danmaku_font")),
            opacity: DanmakuPrefs.opacity(defaults.integer(forKey: "danmaku_opacity")),
            effect: DanmakuPrefs.effect(defaults.integer(forKey: "danmaku_effect")),
            speed: DanmakuPrefs.speed(defaults.integer(forKey: "danmaku_speed")))
    }

    private static func storeDanmaku(_ next: DanmakuSettings) {
        let defaults = UserDefaults.standard
        let normalized = next.normalized()
        defaults.set(normalized.enabled, forKey: "danmaku_enabled")
        defaults.set(DanmakuPrefs.coveragePermille(normalized.coverage), forKey: "danmaku_coverage_permille")
        defaults.set(normalized.font, forKey: "danmaku_font")
        defaults.set(normalized.opacity, forKey: "danmaku_opacity")
        defaults.set(normalized.effect, forKey: "danmaku_effect")
        defaults.set(normalized.speed, forKey: "danmaku_speed")
    }

    func setDanmaku(_ next: DanmakuSettings) { danmaku = next.normalized() }

    func play(_ detail: DramaDetail, index: Int? = nil, resume: LibraryEntry? = nil,
              sleepDeadline: ContinuousClock.Instant? = nil, present: (PlaybackRequest) -> Void) {
        guard !detail.episodes.isEmpty else { openError = "这部剧暂时没有可播放剧集。"; return }
        DramaDetails.remember(detail)
        let entry = resume ?? latestProgress(for: detail.drama.id)
        let selected = index ?? entry.flatMap { entry in detail.episodes.firstIndex { $0.id == entry.episodeID } ?? detail.episodes.firstIndex { $0.index == entry.episodeIndex } } ?? 0
        let bounded = min(max(selected, 0), detail.episodes.count - 1)
        let savedPosition = entry.map { ($0.episodeID == detail.episodes[bounded].id || $0.episodeIndex == detail.episodes[bounded].index) ? $0.position : 0 } ?? 0
        present(PlaybackRequest(detail: detail, index: bounded, position: savedPosition, recordsLocalHistory: resume == nil, sleepDeadline: sleepDeadline))
    }

    /// Where this drama was left: this device's history or the account's, whichever was watched more recently, so
    /// an episode watched on another device continues here.
    func latestProgress(for dramaID: String) -> LibraryEntry? {
        let local = library.progress(for: dramaID)
        guard let cloud = AccountService.shared.cloudProgress(for: dramaID) else { return local }
        guard let local else { return cloud }
        return cloud.updatedAt > local.updatedAt.addingTimeInterval(5) ? cloud : local
    }

    func play(_ drama: Drama, present: @escaping @MainActor (PlaybackRequest) -> Void) {
        openPlayback(drama, present: present)
    }

    @discardableResult
    func openPlayback(_ drama: Drama, canPresent: @escaping @MainActor () -> Bool = { true },
                      sleepDeadline: @escaping @MainActor () -> ContinuousClock.Instant? = { nil },
                      present: @escaping @MainActor (PlaybackRequest) -> Void) -> Task<Void, Never> {
        openTask?.cancel()
        let ticket = UUID()
        let sourceTab = tab
        openID = ticket
        openingDramaID = drama.id
        let task = Task { [weak self] in
            defer {
                if let self, self.openID == ticket {
                    self.openID = nil
                    self.openingDramaID = nil
                }
            }
            do {
                async let progress: Void = AccountService.shared.refreshProgress()
                let detail = try await DramaDetails.load(drama)
                await progress
                try Task.checkCancellation()
                guard let self, self.openID == ticket, self.tab == sourceTab, canPresent() else { return }
                self.play(detail, sleepDeadline: sleepDeadline(), present: present)
            } catch is CancellationError { }
            catch {
                if let self, self.openID == ticket, self.tab == sourceTab, !Task.isCancelled, canPresent() { self.openError = friendlyError(error) }
            }
        }
        openTask = task
        return task
    }
}

@MainActor
final class CatalogLoader: ObservableObject {
    enum Restored { case none, fresh, stale }
    @Published private(set) var dramas: [Drama] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    /// Lists with a disk copy (home feeds, unfiltered 发现) set this; every loaded page updates the copy.
    private(set) var cacheKey: String?
    /// The drama on screen in a paged feed. A background refresh keeps it and the pages before it in place.
    var anchorID: String?
    private var offset = 0
    private let cache: ContentCache
    private var snapshot: CatalogSnapshot?
    private var firstPageAt: Date?
    private(set) var restoredSnapshot: CatalogSnapshot?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let coverPrefetch = CoverPrefetchWindow()
    private var coverAnchorID: String?
    private var coverPrefetchEnabled = true
    init(cache: ContentCache = .shared, initialCacheKey: String? = nil) {
        self.cache = cache
        if let initialCacheKey { restore(key: initialCacheKey) }
    }

    var needsRevalidation: Bool {
        !isLoading && !CatalogCacheEntry.isFresh(firstPageAt)
    }

    /// Shows the saved copy for `key` straight away. Without one the list is emptied, ready for a network load.
    @discardableResult
    func restore(key: String?) -> Restored {
        cancel()
        error = nil; refreshError = nil; cacheKey = key; anchorID = nil
        snapshot = nil; restoredSnapshot = nil; firstPageAt = nil; offset = 0; hasMore = false
        guard let key, let saved = cache.catalog(for: key) else {
            dramas = []
            return .none
        }
        dramas = saved.snapshot.dramas; offset = saved.snapshot.nextOffset; hasMore = saved.snapshot.hasMore
        firstPageAt = saved.firstPageAt
        if firstPageAt != nil { snapshot = saved.snapshot; restoredSnapshot = saved.snapshot }
        return CatalogCacheEntry.isFresh(firstPageAt) ? .fresh : .stale
    }

    var pendingRefresh: Task<Void, Never>? { isRefreshing ? task : nil }

    @discardableResult
    func load(reset: Bool = false, inPlace: Bool = false, refreshing: Bool = false,
              fetch: @escaping (Int) async throws -> DramaPage) -> Task<Void, Never>? {
        if let pendingRefresh, refreshing { return pendingRefresh }
        if !reset && !inPlace && (isLoading || (!dramas.isEmpty && !hasMore)) { return nil }
        task?.cancel()
        let ticket = UUID(); generation = ticket
        let requestedOffset = reset || inPlace ? 0 : offset
        if reset && !inPlace { dramas = []; offset = 0; hasMore = false; resetCoverPrefetch() }
        isLoading = true; isRefreshing = refreshing; error = nil
        if requestedOffset == 0 { refreshError = nil }
        let request = Task { [weak self] in
            defer {
                if let self, self.generation == ticket {
                    self.isLoading = false
                    self.isRefreshing = false
                    self.task = nil
                }
            }
            do {
                let page = try await fetch(requestedOffset)
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                if inPlace {
                    let anchor = page.dramas.isEmpty ? nil : self.anchorID
                    let kept = anchor.flatMap { id in self.dramas.firstIndex { $0.id == id } }.map { Array(self.dramas[...$0]) } ?? []
                    var seen = Set(kept.map(\.id))
                    self.dramas = kept + page.dramas.filter { seen.insert($0.id).inserted }
                } else {
                    var existing = Set(self.dramas.map(\.id))
                    let fresh = page.dramas.filter { existing.insert($0.id).inserted }
                    self.dramas += fresh
                }
                self.updateCoverPrefetch()
                self.hasMore = page.hasMore && !page.dramas.isEmpty && page.nextOffset > requestedOffset
                self.offset = page.nextOffset
                self.restoredSnapshot = nil
                self.persist(page, from: requestedOffset)
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                if !inPlace || self.dramas.isEmpty { self.error = friendlyError(error) }
                if refreshing && !self.dramas.isEmpty { self.refreshError = friendlyError(error) }
            }
        }
        task = request
        return request
    }

    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        isLoading = false; isRefreshing = false; resetCoverPrefetch()
    }

    private func persist(_ page: DramaPage, from offset: Int) {
        if offset == 0 { firstPageAt = .now; snapshot = nil }
        guard let cacheKey, let firstPageAt,
              let updated = CatalogSnapshot.updated(after: page, from: offset, previous: snapshot) else { return }
        snapshot = updated
        cache.storeCatalog(updated, for: cacheKey, firstPageAt: firstPageAt)
    }

    /// Call as a row appears. Requests the next page once it is within 12 of the end, so it is in the list before the
    /// user gets there. A failed page waits for the retry button, so a dead network cannot turn scrolling into a loop.
    func itemAppeared(_ drama: Drama, load: () -> Void) {
        if dramas.contains(where: { $0.id == drama.id }) {
            coverAnchorID = drama.id
            updateCoverPrefetch()
        }
        guard hasMore, error == nil, !isLoading, dramas.suffix(12).contains(where: { $0.id == drama.id }) else { return }
        load()
    }

    func setCoverPrefetchEnabled(_ enabled: Bool) {
        guard coverPrefetchEnabled != enabled else { return }
        coverPrefetchEnabled = enabled
        updateCoverPrefetch()
    }

    private func updateCoverPrefetch() {
        guard coverPrefetchEnabled, let coverAnchorID, let index = dramas.firstIndex(where: { $0.id == coverAnchorID }) else {
            coverPrefetch.update([])
            return
        }
        coverPrefetch.update(dramas.dropFirst(index + 1).prefix(9).map(\.coverURL))
    }

    private func resetCoverPrefetch() {
        coverAnchorID = nil
        coverPrefetch.update([])
    }
}

func friendlyError(_ error: Error) -> String {
    if let error = error as? URLError {
        if error.code == .notConnectedToInternet { return "网络未连接，请检查网络后重试。" }
        if error.code == .timedOut { return "请求超时，请稍后重试。" }
    }
    let value = error.localizedDescription
    return value.isEmpty ? "暂时无法加载，请稍后重试。" : value
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d", value / 60, value % 60)
}
