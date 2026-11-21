import SwiftUI
import AVFoundation
import UIKit

struct PlayerScreen: View {
    private enum BackgroundPlayback {
        case foreground, waiting, suspended
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session: PlayerSession
    @StateObject private var surface = PlayerSurface()
    @State private var episodesVisible = false
    @State private var moreVisible = false
    @State private var commentsVisible = false
    @AppStorage("playback.gestureHintDisplays") private var hintDisplays = 0
    @State private var didShowHint = false
    @State private var showingHint = false
    /// 锁定屏幕 in landscape: the controls and every gesture are off; a tap only shows the lock button for a moment.
    @State private var locked = false
    @State private var lockButtonVisible = false
    @State private var backgroundPlayback = BackgroundPlayback.foreground
    /// 短剧详情 over the player; the episode waits paused underneath and goes on when the sheet closes.
    @State private var detailVisible = false
    @State private var resumeAfterDetail = false
    // Page drag: the current picture follows the finger and the neighbouring episode number slides in.
    @State private var pageHeight: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var dragging = false
    @State private var sliding = false
    @State private var slideTarget: Int?
    /// 清屏: only the picture remains until a tap or an inward pinch brings the controls back.
    @State private var cleanScreen = false
    @State private var explicitCleanScreen = false
    @State private var landscape = false
    /// Where the progress was when a hold-then-drag began; set while that drag moves the progress.
    @State private var seekDragStart: Double?
    /// Set when the episode changed under a hold-then-drag; the rest of that gesture moves nothing.
    @State private var seekDragAbandoned = false
    @State private var speedLockZone: SpeedLockZone?
    private var inlineForeground: Bool { scenePhase == .active && !surface.pipInProgress }
    private var waitingForPlayback: Bool {
        session.preparing || session.buffering || (session.isPlaying && !session.rendered)
    }
    /// Holding for 2× hides the same elements, for as long as the hold lasts.
    private var chromeHidden: Bool { !inlineForeground || cleanScreen || session.holding || locked }
    private var awaitsBackgroundSuspension: Bool {
        scenePhase == .background && !surface.pipInProgress && backgroundPlayback != .suspended
    }
    private var sheetVisible: Bool { episodesVisible || moreVisible || detailVisible || commentsVisible }
    /// Just under a picture wider than tall, as in the official app.
    private var fullScreenOffered: Bool {
        !landscape && !chromeHidden && session.rendered && session.error == nil && !dragging && !sliding
            && session.videoSize.width > session.videoSize.height
    }

    private let requestID: UUID

    init(request: PlaybackRequest, model: AppModel) { requestID = request.id; _session = StateObject(wrappedValue: PlayerSession(request: request, app: model)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // The insets keep touches near the controls from reaching the picture; with the controls gone the whole screen responds.
                    Color.clear.frame(height: cleanScreen || locked ? 0 : (geometry.size.height < 420 ? 58 : 70)).allowsHitTesting(false)
                    VideoGestureView(enabled: inlineForeground && !sliding && !sheetVisible && (!session.scrubbing || seekDragStart != nil), locked: locked,
                                     tap: videoTapped, doubleTap: videoDoubleTapped, holdBegan: speedHoldBegan, holdEnded: session.endHold,
                                     lockSpeed: { if session.holding && !sliding && !sheetVisible { session.lockSpeed() } },
                                     dragChanged: dragChanged, dragEnded: dragEnded, dragCancelled: dragCancelled,
                                     navigate: videoSwiped,
                                     seekChanged: seekDragChanged, seekEnded: seekDragEnded, seekCancelled: seekDragCancelled,
                                     pinched: { enabled in if !landscape { setCleanScreen(enabled) } })
                        .overlay {
                            if inlineForeground && session.holding && !sheetVisible && !sliding, let speedLockZone {
                                SpeedLockTarget(zone: speedLockZone)
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("视频画面")
                        .accessibilityValue(session.pausedBySleepTimer ? "已暂停" : session.speedLocked ? "已锁定 2 倍速" : session.isPlaying ? "播放中" : session.player == nil ? "准备中" : "已暂停")
                        .accessibilityHint(videoAccessibilityHint)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { if locked { lockButtonVisible = true } else { session.toggle() } }
                        .accessibilityActions {
                            if !locked {
                                Button(cleanScreen ? "退出清屏" : "清屏播放") { setCleanScreen(!cleanScreen) }
                                Button("下一集", action: session.next)
                                Button("上一集", action: session.previous)
                                if session.canLockSpeed { Button("锁定 2 倍速", action: session.lockSpeed) }
                                if session.speedLocked { Button("解锁倍速", action: session.unlockSpeed) }
                            }
                        }
                        .accessibilityHidden(!inlineForeground)
                    Color.clear.frame(height: cleanScreen || locked ? 0 : (geometry.size.height < 420 ? 76 : 92)).allowsHitTesting(false)
                }.ignoresSafeArea(edges: cleanScreen || locked ? .all : []).zIndex(1)
                if inlineForeground && landscape && (locked ? lockButtonVisible : !chromeHidden) {
                    lockButton.padding(.trailing, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.opacity).zIndex(3)
                }
                if inlineForeground, let start = seekDragStart, session.duration > 0 {
                    SeekDragBadge(target: session.previewPosition, duration: session.duration, delta: session.previewPosition - start)
                        .allowsHitTesting(false).transition(.opacity).zIndex(1.7)
                }
                if fullScreenOffered {
                    GeometryReader { full in
                        let pictureHeight = min(full.size.height, full.size.width * session.videoSize.height / session.videoSize.width)
                        Button(action: enterFullScreen) {
                            Label("全屏观看", systemImage: "rotate.right").font(.footnote.weight(.medium))
                                .padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityIdentifier("player.fullScreen")
                        .position(x: full.size.width / 2, y: (full.size.height + pictureHeight) / 2 + 30)
                    }.ignoresSafeArea().zIndex(1.5).transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: min(geometry.size.height * 0.45, 300)).frame(maxHeight: .infinity, alignment: .bottom).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
                Group {
                    if scenePhase == .active && surface.pipActive {
                        Button(action: surface.stopPictureInPicture) {
                            VStack(spacing: 10) {
                                Image(systemName: "pip.exit").font(.system(size: 34))
                                Text("退出小窗").font(.subheadline)
                            }.foregroundStyle(.white.opacity(0.6))
                        }.buttonStyle(.plain).accessibilityLabel("退出小窗").accessibilityIdentifier("player.pip")
                    }
                    else if !inlineForeground || dragging || sliding { EmptyView() }
                    else if session.pausedBySleepTimer {
                        if !chromeHidden { resumeButton }
                    }
                    else if let error = session.error { errorPanel(error) }
                    else if waitingForPlayback {
                        DelayedPlaybackLoading {
                            if session.preparing { preparationPanel }
                            else { ProgressView("正在缓冲…").tint(.white) }
                        }.id(session.playID).allowsHitTesting(false).accessibilityIdentifier("player.loading")
                    }
                    else if !chromeHidden && !session.isPlaying && session.rendered && session.player != nil {
                        resumeButton
                    }
                }.zIndex(2)
                VStack(spacing: 0) {
                    chrome { topBar }
                    Spacer(minLength: 0)
                    if let end = session.endMessage { chrome { Text(end).font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12) } }
                    chrome { bottomBar(compact: geometry.size.height < 420) }
                }.padding(.horizontal, landscape ? 18 : 16).padding(.top, 2).padding(.bottom, landscape ? 0 : 8).zIndex(2).allowsHitTesting(!sliding)
                if !landscape && !chromeHidden && !dragging && !sliding {
                    sideActions
                        .padding(.trailing, 10)
                        .padding(.bottom, 118)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .zIndex(2.5)
                }
            }.foregroundStyle(.white)
            .overlay(alignment: .topTrailing) {
                if inlineForeground && !locked && !explicitCleanScreen {
                    SpeedLockStatus(locked: session.speedLocked, restoredSpeed: speedLabel,
                                    identifier: "player.speedUnlock", unlock: session.unlockSpeed)
                        .padding(.trailing, 20).padding(.top, 58)
                }
            }
            .animation(.easeOut(duration: 0.18), value: chromeHidden)
            .animation(.easeOut(duration: 0.18), value: lockButtonVisible)
        }
        // The picture sits behind everything at the full screen size, under the home indicator and the camera
        // housing as well, so full screen reaches every edge whatever space the controls take.
        .background {
            GeometryReader { full in
                pages(height: full.size.height)
                    .onAppear { pageHeight = max(full.size.height, 1); landscape = full.size.width > full.size.height }
                    .onChange(of: full.size) { _, size in pageHeight = max(size.height, 1); landscape = size.width > size.height }
            }.background(.black).ignoresSafeArea().allowsHitTesting(false)
        }
        .preferredColorScheme(.dark).statusBarHidden(landscape).persistentSystemOverlays(landscape && inlineForeground && chromeHidden ? .hidden : .automatic)
            .sheet(isPresented: $episodesVisible) {
                PlayerEpisodePanel(session: session) { index in
                    episodesVisible = false
                    if index != session.index { session.go(to: index) }
                    else if session.pausedBySleepTimer { session.toggle() }
                    else if session.error != nil { session.retry() }
                }
            }
            .sheet(isPresented: $moreVisible) {
                PlayerMorePanel(session: session) {
                    moreVisible = false
                    setCleanScreen(true)
                }
            }
            .episodeDiscussion(DiscussionEpisode(seriesID: session.detail.drama.id, episodeID: session.episode.id, number: session.episode.index),
                               player: session.player, playing: session.isPlaying,
                               foreground: inlineForeground, hideDanmaku: explicitCleanScreen,
                               presented: $commentsVisible)
            .sheet(isPresented: $detailVisible, onDismiss: detailClosed) { detailSheet }
            .task {
                surface.bind(session)
                surface.onPiPEnd = { suspendBackgroundPlayback() }
                session.onSlide = { target in slide(to: target) }; session.start()
            }
            .onDisappear { unlock(); session.stop(); surface.unbind() }
            .onChange(of: inlineForeground) { _, foreground in
                if !foreground {
                    session.endHold()
                    seekDragCancelled()
                    seekDragAbandoned = true
                }
            }
            // Only a real move to the background pauses: an episode that is playing then goes on in the small window
            // (the system starts it as the app leaves), and anything else stops as before.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && backgroundPlayback == .foreground { backgroundPlayback = .waiting }
                if phase == .active { restoreFromBackground() }
            }
            .onChange(of: surface.pipPhase) { _, phase in
                if phase == .active && session.pausedBySleepTimer { surface.stopPictureInPicture() }
                else { restoreFromBackground() }
            }
            .onChange(of: session.pausedBySleepTimer) { _, paused in
                if paused {
                    resumeAfterDetail = false
                    dragCancelled()
                    if surface.pipActive { surface.stopPictureInPicture() }
                }
            }
            .task(id: awaitsBackgroundSuspension) {
                guard awaitsBackgroundSuspension else { return }
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { suspendBackgroundPlayback() }
            }
            // An episode that changes mid-drag (autoplay at the end of a 2× hold, for example) ends that drag. The
            // gesture view's own cancellation can arrive during a view update, where its state change is dropped.
            .onChange(of: session.playID) { _, _ in seekDragCancelled(); seekDragAbandoned = true }
            // In full screen the controls step aside after a few seconds of playback.
            .task(id: shouldAutoHideChrome) {
                guard shouldAutoHideChrome else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled, UIApplication.shared.applicationState == .active, !surface.pipInProgress { cleanScreen = true }
            }
            .task(id: lockButtonVisible) {
                guard locked, lockButtonVisible else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { lockButtonVisible = false }
            }
            .onChange(of: sheetVisible) { _, shown in if shown { session.endHold() } }
            .onReceive(session.$error.removeDuplicates().dropFirst()) { error in
                if error != nil { revealChrome(unlocking: true) }
            }
            .onReceive(session.$endMessage.removeDuplicates().dropFirst()) { message in if message != nil { revealChrome() } }
            .onReceive(session.didPausePlayback) { if !explicitCleanScreen { revealChrome() } }
            .task(id: inlineForeground && !chromeHidden && session.rendered && !sheetVisible) {
                guard inlineForeground, !chromeHidden, session.rendered, !sheetVisible,
                      !didShowHint, hintDisplays < 3 else { return }
                didShowHint = true
                hintDisplays += 1
                showingHint = true
                defer { showingHint = false }
                try? await Task.sleep(for: .seconds(4))
            }
    }

    private func restoreFromBackground() {
        guard scenePhase == .active, backgroundPlayback != .foreground, surface.pipPhase != .starting else { return }
        backgroundPlayback = .foreground
        if surface.pipActive { surface.stopPictureInPicture() }
    }

    private func suspendBackgroundPlayback() {
        guard UIApplication.shared.applicationState == .background, !surface.pipInProgress,
              backgroundPlayback != .suspended else { return }
        backgroundPlayback = .suspended
        session.suspend()
    }

    private func revealChrome(unlocking: Bool = false) {
        guard inlineForeground, UIApplication.shared.applicationState == .active else { return }
        setCleanScreen(false)
        if unlocking { unlock() }
    }

    /// A tap shows or hides the controls and a double tap anywhere pauses or resumes; a pause brings the controls back by
    /// itself. There are no side double-tap skips: the progress moves only by holding and then dragging (Android issue #3).
    private func setCleanScreen(_ enabled: Bool) {
        explicitCleanScreen = enabled
        cleanScreen = enabled
    }

    private func videoTapped(at fraction: CGFloat) {
        if locked { lockButtonVisible.toggle() }
        else if cleanScreen { setCleanScreen(false) }
        else { cleanScreen = true }
    }

    private func videoSwiped(_ direction: HorizontalSwipeDirection) {
        guard inlineForeground, !locked, !sheetVisible, !dragging, !sliding, !session.scrubbing else { return }
        if direction == .left { openDetail() }
        else { goBack() }
    }

    private func goBack() {
        if landscape { exitFullScreen() }
        else { session.stop(); dismiss() }
    }

    /// Locking also holds the current landscape, so turning the phone does not leave full screen either.
    private func toggleLock() {
        if locked { unlock(); return }
        guard let scene = surface.view.window?.windowScene, InterfaceOrientationLock.lockLandscape(in: scene) else { return }
        session.endHold(); cleanScreen = false
        locked = true; lockButtonVisible = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func unlock() {
        guard locked else { return }
        locked = false; lockButtonVisible = false
        InterfaceOrientationLock.unlock()
    }

    private var lockButton: some View {
        Button(action: toggleLock) {
            AppControlIcon(name: locked ? "lock.fill" : "lock.open")
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(.white)
            .accessibilityLabel(locked ? "解锁屏幕" : "锁定屏幕").accessibilityIdentifier("player.lock")
    }

    private func videoDoubleTapped(at fraction: CGFloat) {
        if session.player != nil || session.pausedBySleepTimer { session.toggle() }
    }

    private var videoAccessibilityHint: String {
        if locked { return "显示解锁屏幕按钮" }
        return (session.isPlaying ? "轻点暂停" : "轻点继续播放")
            + "，左滑查看详情，右滑返回，长按后左右拖动调整进度，上下拖动切换剧集"
    }

    private func speedHoldBegan(_ zone: SpeedLockZone) -> Bool {
        seekDragAbandoned = false
        session.beginHold()
        guard session.holding else { return false }
        speedLockZone = zone
        return true
    }

    // Hold until 2×, then drag sideways to move the progress: the 2× ends, the time shows in the middle and the jump
    // happens on release. A drag without the hold never seeks. It shares the slider's preview, so the bar follows.
    private func seekDragChanged(_ fraction: CGFloat) {
        guard !seekDragAbandoned else { return }
        if seekDragStart == nil {
            let start = session.position
            guard session.beginDragSeek() else { return }
            seekDragStart = start
        }
        guard let start = seekDragStart else { return }
        session.previewPosition = PlayerSession.dragSeekTarget(start: start, duration: session.duration, fraction: Double(fraction))
    }

    private func seekDragEnded(_ fraction: CGFloat) {
        seekDragAbandoned = false
        guard let start = seekDragStart else { return }
        session.previewPosition = PlayerSession.dragSeekTarget(start: start, duration: session.duration, fraction: Double(fraction))
        seekDragStart = nil
        session.endDragSeek(from: start, commit: true)
    }

    private func seekDragCancelled() {
        if seekDragStart == nil, seekDragAbandoned { seekDragAbandoned = false }
        guard let start = seekDragStart else { return }
        seekDragStart = nil
        session.endDragSeek(from: start, commit: false)
    }

    private func openDetail() {
        resumeAfterDetail = session.isPlaying
        if session.isPlaying { session.pause() }
        detailVisible = true
    }

    private func detailClosed() {
        // Playing an episode from the detail page replaces this player, so nothing resumes behind the new one.
        if resumeAfterDetail, !session.isPlaying, !session.pausedBySleepTimer,
           session.app.playback?.id == requestID { session.toggle() }
        resumeAfterDetail = false
    }

    private var shouldAutoHideChrome: Bool {
        landscape && !chromeHidden && session.isPlaying && !session.scrubbing && !sheetVisible
    }

    private func enterFullScreen() { requestOrientation(.landscape) }
    private func exitFullScreen() { requestOrientation(.portrait) }

    private func requestOrientation(_ orientation: UIInterfaceOrientationMask) {
        revealChrome()
        surface.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    /// Controls fade out with the screen and stop taking touches and VoiceOver focus.
    private func chrome(@ViewBuilder content: () -> some View) -> some View {
        content().opacity(chromeHidden ? 0 : 1).allowsHitTesting(!chromeHidden).accessibilityHidden(chromeHidden)
    }

    // MARK: Episode paging

    /// The episode whose page fills most of the screen, so labels change half-way through a drag like a pager.
    private var visibleEpisode: Episode {
        let episodes = session.detail.episodes
        if dragOffset <= -pageHeight / 2 { return episodes[min(slideTarget ?? session.index + 1, episodes.count - 1)] }
        if dragOffset >= pageHeight / 2 { return episodes[max(slideTarget ?? session.index - 1, 0)] }
        return session.episode
    }

    private func pages(height: CGFloat) -> some View {
        let count = session.detail.episodes.count
        let above = slideTarget.flatMap { $0 < session.index ? $0 : nil } ?? session.index - 1
        let below = slideTarget.flatMap { $0 > session.index ? $0 : nil } ?? session.index + 1
        return ZStack {
            if above >= 0 { neighbourPage(above).offset(y: dragOffset - height) }
            currentPage.offset(y: dragOffset)
            if below < count { neighbourPage(below).offset(y: dragOffset + height) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .onChange(of: dragging || sliding) { _, moving in
                if moving { surface.holdDisplayedFrame(ticket: session.playID) }
                else { surface.releaseHeldFrame(ticket: session.playID) }
            }
    }

    private var currentPage: some View {
        ZStack {
            Color.black
            PlayerSurfaceView(surface: surface)
            if !surface.pipInProgress, surface.displayedPlayID != session.playID,
               let frame = session.transitionFrame ?? surface.heldFrame {
                VideoFrameView(image: frame)
                    .transition(.identity)
            }
        }
    }

    private func neighbourPage(_ index: Int) -> some View {
        ZStack {
            if let frame = PlaybackLookahead.frame(PlaybackTarget(session.detail, index: index, quality: session.quality))
                ?? surface.heldFrame {
                VideoFrameView(image: frame)
            }
            else { Color.black }
        }
    }

    private func dragChanged(_ translation: CGFloat) {
        guard !sliding, !locked, !sheetVisible, inlineForeground else { return }
        if !dragging { dragging = true; session.holdForGesture() }
        let atFirst = session.index == 0 && translation > 0
        let atLast = session.index + 1 >= session.detail.episodes.count && translation < 0
        dragOffset = atFirst || atLast ? translation * 0.28 : translation
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        guard dragging else { return }
        dragging = false
        let projected = translation + velocity * 0.18
        let direction = projected <= -pageHeight * 0.3 ? 1 : (projected >= pageHeight * 0.3 ? -1 : 0)
        let target = session.index + direction
        if direction != 0, session.detail.episodes.indices.contains(target) {
            if session.pausedBySleepTimer {
                dragOffset = 0
                session.go(to: target)
            } else { commitSlide(to: target) }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
        if scenePhase == .active { session.releaseGesture() }
        if direction == 1 { session.next() } else if direction == -1 { session.previous() }
    }

    private func dragCancelled() {
        guard dragging else { return }
        dragging = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
        if scenePhase == .active { session.releaseGesture() }
    }

    /// Autoplay, buttons and the episode sheet slide the same way a swipe does. Touches are off until the slide ends.
    private func slide(to target: Int) {
        guard !sliding, !dragging, target != session.index, session.detail.episodes.indices.contains(target) else { return }
        if landscape || !inlineForeground { session.load(index: target, startAt: 0); return }
        session.holdForGesture()
        commitSlide(to: target)
    }

    private func commitSlide(to target: Int) {
        let direction: CGFloat = target > session.index ? 1 : -1
        sliding = true; slideTarget = target
        withAnimation(.easeInOut(duration: 0.32)) { dragOffset = -direction * pageHeight } completion: {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                session.load(index: target, startAt: 0)
                dragOffset = 0; slideTarget = nil; sliding = false
            }
            if backgroundPlayback == .suspended && UIApplication.shared.applicationState == .background { session.suspend() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 4) {
            Button(action: goBack) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.left").font(.title3.weight(.medium))
                    if !landscape { episodeHeading }
                }
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel(landscape ? "退出全屏" : "关闭播放器")
                .accessibilityValue(landscape ? "" : "第 \(visibleEpisode.index) 集")
                .accessibilityIdentifier(landscape ? "player.exitFullScreen" : "player.close")
            if landscape { dramaTitle; episodeHeading }
            Spacer(minLength: 6)
            Button { moreVisible = true } label: {
                AppControlIcon(name: "ellipsis")
            }.accessibilityLabel("更多").accessibilityIdentifier("player.more")
        }.buttonStyle(.plain).shadow(color: .black.opacity(0.55), radius: 2, y: 1)
    }

    private var episodeHeading: some View {
        Text("第 \(visibleEpisode.index) 集").font(.title3.weight(.semibold)).monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }

    private var dramaTitle: some View {
        Button(action: openDetail) {
            HStack(spacing: 5) {
                Text(session.detail.drama.title).font(.body.weight(.medium)).lineLimit(1)
                if !landscape { Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(session.detail.drama.title)，第 \(visibleEpisode.index) 集")
            .accessibilityHint("打开短剧详情").accessibilityIdentifier("player.dramaTitle")
    }

    private var sideActions: some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 4))
        return layout {
            let favorite = library.isFavorite(session.detail.drama)
            Button { library.toggleFavorite(session.detail.drama) } label: {
                AppControlIcon(name: AppSymbol.favorite(favorite))
            }.accessibilityLabel(favorite ? "取消本机收藏" : "添加本机收藏").accessibilityIdentifier("player.favorite")
            DiscussionControls(vertical: !landscape) { commentsVisible = true }
        }.buttonStyle(.plain).shadow(color: .black.opacity(0.8), radius: 2, y: 1)
    }

    private var preparationPanel: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(session.stage).font(.footnote)
        }.shadow(radius: 3)
    }

    private var resumeButton: some View {
        Button(action: session.toggle) {
            Image(systemName: "play.fill").font(.system(size: 40, weight: .semibold))
                .shadow(radius: 4).frame(width: 64, height: 64)
        }.buttonStyle(.plain).accessibilityLabel("继续播放")
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) { Image(systemName: "exclamationmark.circle").font(.largeTitle); Text(message).font(.subheadline).multilineTextAlignment(.center).lineLimit(5); HStack(spacing: 15) { Button("重试", action: session.retry).buttonStyle(.borderedProminent).tint(Color(hex: 0xC94426)); Button("选择其他集") { episodesVisible = true }.buttonStyle(.bordered) } }.padding(25).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private func bottomBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 3) {
            if !landscape { dramaTitle.padding(.trailing, 52) }
            if showingHint {
                Text("长按 2× · 纵滑锁定 · 横滑调进度").font(.caption2)
                    .foregroundStyle(.white.opacity(0.75)).accessibilityIdentifier("player.gestureHint")
            }
            HStack(spacing: 10) {
                Text(timeLabel(session.scrubbing ? session.previewPosition : session.position)).font(.caption.monospacedDigit()).frame(minWidth: 36)
                Slider(value: Binding(get: { session.scrubbing ? session.previewPosition : session.position }, set: { session.previewPosition = $0 }), in: 0...max(session.duration, 1), onEditingChanged: session.setSeeking).tint(session.app.appearance.accent).disabled(session.duration <= 0).accessibilityLabel("播放进度")
                Text(timeLabel(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).frame(minWidth: 36)
            }
            HStack(spacing: 8) {
                if landscape {
                    sideActions
                    Spacer(minLength: 8)
                }
                Button { episodesVisible = true } label: {
                    PlaybackEpisodeStrip(title: "选集", detail: "全 \(session.detail.episodes.count) 集")
                }.fixedSize(horizontal: landscape, vertical: false).accessibilityIdentifier("player.episodes")
            }.buttonStyle(.plain)
        }
    }

    /// The same page the library and home open, themed like them rather than like the dark player.
    private var detailSheet: some View {
        NavigationStack {
            DetailView(drama: session.detail.drama)
                .background(NavigationBackSwipe(dismissRoot: { detailVisible = false }))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detailVisible = false } } }
        }.environment(\.colorScheme, session.app.isDark ? .dark : .light).preferredColorScheme(session.app.isDark ? .dark : .light)
        .presentationDragIndicator(.visible)
    }

    private var speedLabel: String { String(format: "%g×", session.app.speed) }

}

struct DelayedPlaybackLoading<Content: View, Fallback: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let fallback: () -> Fallback
    @State private var visible = false

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            if visible { content() } else { fallback() }
        }.task {
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { visible = true }
        }
    }
}

extension DelayedPlaybackLoading where Fallback == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, fallback: EmptyView.init)
    }
}

struct SeekDragBadge: View {
    let target: Double
    let duration: Double
    let delta: Double
    var body: some View {
        VStack(spacing: 4) {
            Text("\(timeLabel(target)) / \(timeLabel(duration))").font(.title3.weight(.semibold).monospacedDigit())
            Text("\(delta >= 0 ? "快进" : "快退") \(Int(abs(delta))) 秒").font(.caption).foregroundStyle(.white.opacity(0.75))
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine).accessibilityIdentifier("player.dragSeek")
    }
}

struct SpeedLockTarget: View {
    let zone: SpeedLockZone

    var body: some View {
        GeometryReader { geometry in
            let frame = zone.frame(in: CGRect(origin: .zero, size: geometry.size))
            Label(zone == .upper ? "2× 播放中 · 向上滑入锁定" : "2× 播放中 · 向下滑入锁定",
                  systemImage: zone == .upper ? "arrow.up" : "arrow.down")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(width: frame.width, height: frame.height)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.65)) }
                .position(x: frame.midX, y: frame.midY)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SpeedLockStatus: View {
    let locked: Bool
    let restoredSpeed: String
    let identifier: String
    let unlock: () -> Void
    @State private var unlockedMessage: String?

    var body: some View {
        ZStack {
            if locked {
                Button(action: unlock) {
                    badge("2× 已锁定 · 解锁", icon: "lock.fill")
                }.buttonStyle(.plain)
                    .accessibilityLabel("解锁倍速")
                    .accessibilityValue("已锁定 2 倍速")
                    .accessibilityIdentifier(identifier)
            } else if let unlockedMessage {
                badge(unlockedMessage, icon: "lock.open")
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .allowsHitTesting(locked)
        .onChange(of: locked) { _, locked in
            unlockedMessage = locked ? nil : "已解锁 · 恢复 \(restoredSpeed)"
            if locked {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            UIAccessibility.post(notification: .announcement,
                                 argument: locked ? "已锁定 2 倍速" : "已解锁，恢复 \(restoredSpeed)")
        }
        .task(id: unlockedMessage) {
            guard unlockedMessage != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { unlockedMessage = nil }
        }
    }

    private func badge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(.black.opacity(0.82), in: Capsule()).contentShape(Capsule())
    }
}
