import SwiftUI
import AVFoundation
import UIKit

struct PlayerScreen: View {
    private enum BackgroundPlayback {
        case foreground, waiting, suspended
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session: PlayerSession
    @StateObject private var surface = PlayerSurface()
    @State private var episodesVisible = false
    @State private var moreVisible = false
    @State private var commentsVisible = false
    @AppStorage(PortraitVideoPosition.key) private var portraitVideoPosition: PortraitVideoPosition = .center
    @AppStorage("playback.gestureHintDisplays") private var hintDisplays = 0
    @State private var didShowHint = false
    @State private var showingHint = false
    /// 锁定屏幕 in landscape: the controls and every gesture are off; a tap only shows the lock button for a moment.
    @State private var locked = false
    @State private var lockButtonVisible = false
    @State private var backgroundPlayback = BackgroundPlayback.foreground
    @State private var started = false
    @State private var detailVisible = false
    @State private var resumeAfterDetail = false
    @State private var detailSelectedIndex = 0
    @State private var detailSwipe: DetailSwipe?
    @State private var detailReveal: CGFloat = 0
    @State private var detailHandoffCover: UIView?
    @State private var pageWidth: CGFloat = 1
    private struct DetailSwipe {
        let token = UUID()
        let playID: UUID
        let item: AVPlayerItem?
        var settling = false
    }
    private struct PageMotion {
        let token = UUID()
        let origin: UUID
        var settling = false
        var target: Int?
    }

    @State private var pageHeight: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var pageMotion: PageMotion?
    @State private var pagingPosterTicket: UUID?
    private var dragging: Bool { pageMotion?.settling == false }
    private var sliding: Bool { pageMotion?.settling == true }
    private var pageMoving: Bool { pageMotion != nil }
    /// 清屏: only the picture remains until a tap or an inward pinch brings the controls back.
    @State private var cleanScreen = false
    @State private var explicitCleanScreen = false
    @State private var landscape = false
    /// Where the progress was when a hold-then-drag began; set while that drag moves the progress.
    @State private var seekDragStart: Double?
    /// Set when the episode changed under a hold-then-drag; the rest of that gesture moves nothing.
    @State private var seekDragAbandoned = false
    @State private var speedLockZone: SpeedLockZone?
    private var inlineForeground: Bool { scenePhase == .active && !surface.pipInProgress && !detailVisible }
    private var waitingForPlayback: Bool {
        session.preparing || session.buffering || (session.isPlaying && !session.rendered)
    }
    /// Holding for 2× hides the same elements, for as long as the hold lasts.
    private var chromeHidden: Bool { !inlineForeground || cleanScreen || session.holding || locked }
    private var awaitsBackgroundSuspension: Bool {
        scenePhase == .background && !detailVisible && !surface.pipInProgress && backgroundPlayback != .suspended
    }
    private var sheetVisible: Bool { episodesVisible || moreVisible || detailVisible || commentsVisible }
    private var canSwipeDetail: Bool {
        inlineForeground && !locked && !sheetVisible && !dragging && !sliding && !session.scrubbing && !session.holding
    }
    private var approachingEpisodeEnd: Bool {
        guard let player = session.player, player.rate > 0, let item = player.currentItem else { return false }
        let remaining = item.duration.seconds - player.currentTime().seconds
        return remaining.isFinite && remaining <= max(1, Double(player.rate))
    }
    /// Just under a picture wider than tall, as in the official app.
    private var fullScreenOffered: Bool {
        !landscape && !chromeHidden && session.rendered && session.error == nil && !dragging && !sliding
            && session.videoSize.width > session.videoSize.height
    }

    private let request: PlaybackRequest
    private let replacePlayback: (PlaybackRequest) -> Void

    init(request: PlaybackRequest, model: AppModel, replacePlayback: @escaping (PlaybackRequest) -> Void) {
        self.request = request
        self.replacePlayback = replacePlayback
        _session = StateObject(wrappedValue: PlayerSession(request: request, app: model))
    }

    var body: some View {
        playerPresentation(playerPage)
    }

    private var playerPage: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let canvas = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                height: geometry.size.height + insets.top + insets.bottom)
            let layout = PlaybackPictureLayout(canvas: canvas, insets: insets, position: portraitVideoPosition, context: .player)
            ZStack {
                pictureGestures
                playerChrome(size: geometry.size, layout: layout)
                    .offset(y: dragOffset)
                    .allowsHitTesting(!pageMoving && detailSwipe == nil && (!chromeHidden || surface.pipActive || session.speedLocked))
                    .accessibilityHidden(pageMoving)
                if pageMoving && !chromeHidden { neighbouringEpisodeHeadings }
                if inlineForeground && landscape && detailSwipe == nil && (locked ? lockButtonVisible : !chromeHidden) {
                    lockButton
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(y: dragOffset)
                        .allowsHitTesting(!pageMoving)
                        .transition(.opacity)
                }
            }.foregroundStyle(.white)
            .opacity(detailSwipe == nil ? 1 : 1 - 0.18 * detailReveal)
            .animation(.easeOut(duration: 0.18), value: chromeHidden)
            .animation(.easeOut(duration: 0.18), value: lockButtonVisible)
            .background {
                GeometryReader { full in
                    let fullLayout = PlaybackPictureLayout(canvas: full.size, insets: insets,
                                                           position: portraitVideoPosition, context: .player)
                    pages(layout: fullLayout)
                        .onAppear { updatePlayerGeometry(full.size) }
                        .onChange(of: full.size) { _, size in updatePlayerGeometry(size) }
                }.background(.black).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark).statusBarHidden(landscape).persistentSystemOverlays(landscape && inlineForeground && chromeHidden ? .hidden : .automatic)
    }

    private var pictureGestures: some View {
        VideoGestureView(enabled: inlineForeground && !sliding && !sheetVisible && (!session.scrubbing || seekDragStart != nil), locked: locked,
                         tap: videoTapped, doubleTap: videoDoubleTapped, holdBegan: speedHoldBegan, holdEnded: session.endHold,
                         lockSpeed: { if session.holding && !sliding && !sheetVisible { session.lockSpeed() } },
                         dragBegan: dragBegan, dragChanged: dragChanged, dragEnded: dragEnded, dragCancelled: dragCancelled,
                         allowsRightSwipe: landscape,
                         detailDragBegan: detailDragBegan, detailDragChanged: detailDragChanged, detailDragEnded: detailDragEnded,
                         detailDragCancelled: cancelDetailSwipe, exitFullScreen: videoSwipedRight,
                         seekChanged: seekDragChanged, seekEnded: seekDragEnded, seekCancelled: seekDragCancelled,
                         pinched: { enabled in if !landscape && detailSwipe == nil { setCleanScreen(enabled) } })
            .overlay {
                if inlineForeground && session.holding && !sheetVisible && !sliding, let speedLockZone {
                    SpeedLockTarget(zone: speedLockZone)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("视频画面")
            .accessibilityValue(session.pausedBySleepTimer ? "已暂停" : session.speedLocked ? "已锁定 2 倍速" : session.isPlaying ? "播放中" : session.player == nil ? "准备中" : "已暂停")
            .accessibilityHint(videoAccessibilityHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard detailSwipe == nil, !pageMoving else { return }
                if locked { lockButtonVisible = true } else { session.toggle() }
            }
            .accessibilityActions {
                if !locked && !pageMoving {
                    Button(cleanScreen ? "退出清屏" : "清屏播放") { setCleanScreen(!cleanScreen) }
                    Button("下一集", action: session.next)
                    Button("上一集", action: session.previous)
                    if session.canLockSpeed { Button("锁定 2 倍速", action: session.lockSpeed) }
                    if session.speedLocked { Button("解锁倍速", action: session.unlockSpeed) }
                }
            }
            .accessibilityHidden(!inlineForeground || detailSwipe != nil)
    }

    private func playerChrome(size: CGSize, layout: PlaybackPictureLayout) -> some View {
        let picture = layout.portraitWideFrame(for: transitionPicture?.size ?? session.videoSize)
        let safePicture = picture?.offsetBy(dx: -layout.insets.leading, dy: -layout.insets.top)
        let pictureOffsetY = safePicture.map { $0.midY - size.height / 2 } ?? 0
        let pictureOffsetX = safePicture.map { $0.midX - size.width / 2 } ?? 0
        let dockInteractions = layout.overlapsInteractionColumn(picture)
        return ZStack {
            if inlineForeground, let start = seekDragStart, session.duration > 0 {
                SeekDragBadge(target: session.previewPosition, duration: session.duration, delta: session.previewPosition - start)
                    .offset(x: pictureOffsetX, y: pictureOffsetY)
                    .allowsHitTesting(false).transition(.opacity).zIndex(1.7)
            }
            if fullScreenOffered, let safePicture {
                Button(action: enterFullScreen) {
                    Label("全屏观看", systemImage: "rotate.right").font(.footnote.weight(.medium))
                        .padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .frame(minHeight: layout.context.accessoryRoom).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("player.fullScreen")
                    .position(x: safePicture.midX, y: safePicture.maxY + layout.context.accessoryRoom / 2)
                    .zIndex(1.5).transition(.opacity)
            }
            if picture == nil {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: min(size.height * 0.45, 300)).frame(maxHeight: .infinity, alignment: .bottom).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
            }
            Group {
                if scenePhase == .active && surface.pipActive {
                    Button(action: surface.stopPictureInPicture) {
                        VStack(spacing: 10) {
                            Image(systemName: "pip.exit").font(.system(size: 34))
                            Text("退出小窗").font(.subheadline)
                        }.foregroundStyle(.white.opacity(0.6))
                    }.buttonStyle(.plain).accessibilityLabel("退出小窗").accessibilityIdentifier("player.pip")
                }
                else if !inlineForeground { EmptyView() }
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
            }
            .offset(x: surface.pipActive ? 0 : pictureOffsetX, y: surface.pipActive ? 0 : pictureOffsetY)
            .zIndex(2)
            if !chromeHidden {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let end = session.endMessage { Text(end).font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12) }
                    bottomBar(compact: size.height < 420, dockInteractions: dockInteractions)
                }.padding(.horizontal, landscape ? 18 : 16).padding(.top, 2).padding(.bottom, landscape ? 0 : 8)
                    .transition(.opacity).zIndex(2)
            }
            if !landscape && !dockInteractions && !chromeHidden {
                sideActions(horizontal: false)
                    .padding(.trailing, 10)
                    .padding(.bottom, 118)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(2.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if inlineForeground && !locked && !explicitCleanScreen {
                SpeedLockStatus(locked: session.speedLocked, restoredSpeed: speedLabel,
                                identifier: "player.speedUnlock", unlock: session.unlockSpeed)
                    .padding(.trailing, picture == nil ? 20 : 66).padding(.top, picture == nil ? 58 : 4)
            }
        }
        .episodeDiscussion(DiscussionEpisode(seriesID: session.detail.drama.id, episodeID: session.episode.id, number: session.episode.index),
                           player: session.player, foreground: inlineForeground,
                           hideDanmaku: explicitCleanScreen,
                           danmakuInsets: layout.danmakuInsets(around: picture),
                           presented: $commentsVisible)
    }

    private func playerPresentation<Content: View>(_ content: Content) -> some View {
        content
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
            .overlay { detailSwipeOverlay }
            .background(InteractiveBackSwipe(enabled: inlineForeground && !landscape && !locked && !sheetVisible
                                             && !dragging && !sliding && !session.scrubbing && !session.holding && detailSwipe == nil))
            .navigationDestination(isPresented: $detailVisible) {
                DetailView(detail: session.detail, selected: detailSelectedIndex, loadsContent: detailHandoffCover == nil)
                    .background(PlayerDetailArrival(arrived: finishDetailHandoff))
            }
            .onChange(of: detailVisible) { _, shown in if !shown { detailClosed() } }
            .onAppear { if !detailVisible { session.app.showPlayback(request) } }
            .task {
                guard !started else { return }
                started = true
                surface.bind(session)
                surface.onPiPEnd = { suspendBackgroundPlayback() }
                session.onSeasonPlayback = replacePlayback
                session.onSlide = { target in slide(to: target) }; session.start()
            }
            .onDisappear {
                resetDetailSwipe()
                resetEpisodePaging()
                session.app.hidePlayback(request.id)
                if !detailVisible { unlock(); session.stop(); surface.unbind() }
            }
            .onChange(of: inlineForeground) { _, foreground in
                if !foreground {
                    resetEpisodePaging()
                    session.endHold()
                    seekDragCancelled()
                    seekDragAbandoned = true
                }
            }
            // Only a real move to the background pauses: an episode that is playing then goes on in the small window
            // (the system starts it as the app leaves), and anything else stops as before.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { finishDetailHandoff() }
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
                    resetDetailSwipe()
                    resetEpisodePaging()
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
            .onChange(of: session.playID) { _, _ in
                resetDetailSwipe()
                if let motion = pageMotion, motion.origin != session.playID { resetEpisodePaging() }
                seekDragCancelled()
                seekDragAbandoned = true
            }
            .onChange(of: surface.displayedPlayID) { _, ticket in
                if ticket == pagingPosterTicket { pagingPosterTicket = nil }
            }
            .onChange(of: canSwipeDetail) { _, allowed in if !allowed { resetDetailSwipe() } }
            .onChange(of: session.position) { _, _ in
                if detailSwipe != nil && approachingEpisodeEnd { resetDetailSwipe() }
            }
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
            .onChange(of: sheetVisible) { _, shown in
                if shown {
                    resetEpisodePaging()
                    session.endHold()
                }
            }
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
        guard detailSwipe == nil, !pageMoving else { return }
        if locked { lockButtonVisible.toggle() }
        else if cleanScreen { setCleanScreen(false) }
        else { cleanScreen = true }
    }

    private func videoSwipedRight() {
        guard canSwipeDetail, detailSwipe == nil, landscape else { return }
        exitFullScreen()
    }

    private func goBack() {
        if landscape { exitFullScreen() }
        else { dismiss() }
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
        guard detailSwipe == nil, !pageMoving else { return }
        if session.player != nil || session.pausedBySleepTimer { session.toggle() }
    }

    private var videoAccessibilityHint: String {
        if locked { return "显示解锁屏幕按钮" }
        let back = landscape ? "右滑退出全屏" : "右滑返回"
        return (session.isPlaying ? "轻点暂停" : "轻点继续播放")
            + "，左滑查看详情，\(back)，长按后左右拖动调整进度，上下拖动切换剧集"
    }

    private func speedHoldBegan(_ zone: SpeedLockZone) -> Bool {
        guard detailSwipe == nil, !pageMoving else { return false }
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

    private func updatePlayerGeometry(_ size: CGSize) {
        if pageWidth != size.width || pageHeight != size.height {
            resetDetailSwipe()
            resetEpisodePaging()
        }
        pageWidth = max(size.width, 1)
        pageHeight = max(size.height, 1)
        landscape = size.width > size.height
    }

    private func detailDragBegan(_ distance: CGFloat) {
        guard canSwipeDetail, detailSwipe == nil, !approachingEpisodeEnd else { return }
        detailSwipe = DetailSwipe(playID: session.playID, item: session.player?.currentItem)
        detailDragChanged(distance)
    }

    private func detailDragChanged(_ distance: CGFloat) {
        guard let swipe = detailSwipe, !swipe.settling else { return }
        guard canContinueDetailSwipe(swipe) else { resetDetailSwipe(); return }
        detailReveal = min(max(distance / pageWidth, 0), 1)
    }

    private func detailDragEnded(_ distance: CGFloat, _ velocity: CGFloat) {
        guard let swipe = detailSwipe, !swipe.settling else { return }
        let projected = distance + velocity * 0.18
        let commit = canContinueDetailSwipe(swipe) && distance >= min(64, pageWidth * 0.15)
            && (distance >= pageWidth * 0.38 || projected >= pageWidth * 0.32)
            && velocity > -250
        settleDetailSwipe(commit: commit)
    }

    private func canContinueDetailSwipe(_ swipe: DetailSwipe) -> Bool {
        canSwipeDetail && swipe.playID == session.playID && !approachingEpisodeEnd
            && (swipe.item == nil || swipe.item === session.player?.currentItem)
    }

    private func cancelDetailSwipe() {
        guard detailSwipe?.settling == false else { return }
        settleDetailSwipe(commit: false)
    }

    private func settleDetailSwipe(commit: Bool) {
        guard let swipe = detailSwipe else { return }
        detailSwipe?.settling = true
        withAnimation(.easeOut(duration: reduceMotion ? 0 : (commit ? 0.22 : 0.20)), completionCriteria: .removed) {
            detailReveal = commit ? 1 : 0
        } completion: {
            guard detailSwipe?.token == swipe.token else { return }
            if commit && canContinueDetailSwipe(swipe) {
                coverDetailHandoff()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { openDetail() }
            } else { resetDetailSwipe() }
        }
    }

    private func resetDetailSwipe() {
        detailSwipe = nil
        detailReveal = 0
    }

    private func coverDetailHandoff() {
        guard let window = surface.view.window, let cover = window.snapshotView(afterScreenUpdates: true) else { return }
        cover.frame = window.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.accessibilityElementsHidden = true
        window.addSubview(cover)
        detailHandoffCover = cover
        Task { @MainActor [weak cover] in
            try? await Task.sleep(for: .seconds(1))
            if let cover, detailHandoffCover === cover { finishDetailHandoff() }
        }
    }

    private func finishDetailHandoff() {
        detailHandoffCover?.removeFromSuperview()
        detailHandoffCover = nil
    }

    private var detailSwipeOverlay: some View {
        GeometryReader { geometry in
            if detailSwipe != nil {
                DetailView(detail: session.detail, selected: session.index, transitionPreview: true)
                    .shadow(color: .black.opacity(0.25), radius: 12)
                    .offset(x: geometry.size.width * (1 - detailReveal))
                    .transition(.identity)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func openDetail() {
        guard !detailVisible else { return }
        detailSelectedIndex = session.index
        resumeAfterDetail = session.preparing || session.isPlaying || session.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if resumeAfterDetail { session.pause() }
        detailVisible = true
    }

    private func detailClosed() {
        finishDetailHandoff()
        session.app.showPlayback(request)
        if resumeAfterDetail, !session.isPlaying, !session.pausedBySleepTimer {
            try? AVAudioSession.sharedInstance().setActive(true)
            session.toggle()
        }
        resumeAfterDetail = false
    }

    private var shouldAutoHideChrome: Bool {
        landscape && !chromeHidden && session.isPlaying && !session.scrubbing && !sheetVisible && detailSwipe == nil && !pageMoving
    }

    private func enterFullScreen() { requestOrientation(.landscape) }
    private func exitFullScreen() { requestOrientation(.portrait) }

    private func requestOrientation(_ orientation: UIInterfaceOrientationMask) {
        revealChrome()
        surface.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }

    // MARK: Episode paging

    private var previousPage: Int {
        pageMotion?.target.flatMap { $0 < session.index ? $0 : nil } ?? session.index - 1
    }

    private var nextPage: Int {
        pageMotion?.target.flatMap { $0 > session.index ? $0 : nil } ?? session.index + 1
    }

    private var neighbouringEpisodeHeadings: some View {
        ZStack(alignment: .topLeading) {
            if previousPage >= 0 {
                episodeHeading(session.detail.episodes[previousPage]).offset(y: dragOffset - pageHeight)
            }
            if nextPage < session.detail.episodes.count {
                episodeHeading(session.detail.episodes[nextPage]).offset(y: dragOffset + pageHeight)
            }
        }
        .padding(.leading, landscape ? 18 : 44)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func pages(layout: PlaybackPictureLayout) -> some View {
        ZStack {
            if pageMoving && previousPage >= 0 { neighbourPage(previousPage, layout: layout).offset(y: dragOffset - layout.canvas.height) }
            currentPage(layout: layout).offset(y: dragOffset)
            if pageMoving && nextPage < session.detail.episodes.count { neighbourPage(nextPage, layout: layout).offset(y: dragOffset + layout.canvas.height) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }

    private var transitionPicture: UIImage? {
        guard !surface.pipInProgress, surface.displayedPlayID != session.playID else { return nil }
        return session.transitionFrame ?? (pagingPosterTicket == session.playID ? nil : surface.heldFrame)
    }

    private func currentPage(layout: PlaybackPictureLayout) -> some View {
        ZStack {
            Color.black
            PlayerSurfaceView(surface: surface)
                .playbackPictureFrame(layout.frame(for: session.videoSize == .zero ? transitionPicture?.size ?? .zero : session.videoSize))
            if !surface.pipInProgress, surface.displayedPlayID != session.playID {
                if let frame = transitionPicture {
                    VideoFrameView(image: frame).playbackPictureFrame(layout.frame(for: frame.size)).transition(.identity)
                } else if pagingPosterTicket == session.playID {
                    episodePagePoster.transition(.identity)
                }
            }
        }
    }

    private func neighbourPage(_ index: Int, layout: PlaybackPictureLayout) -> some View {
        ZStack {
            Color.black
            if let frame = PlaybackLookahead.frame(PlaybackTarget(session.detail, index: index, quality: session.quality)) {
                VideoFrameView(image: frame).playbackPictureFrame(layout.frame(for: frame.size))
            } else {
                episodePagePoster
            }
        }
    }

    private var episodePagePoster: some View {
        Color.black.overlay {
            GeometryReader { geometry in
                PosterView(drama: session.detail.drama)
                    .frame(width: min(geometry.size.width * 0.55, geometry.size.height * 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var allowsEpisodeDrag: Bool {
        inlineForeground && !locked && !sheetVisible && detailSwipe == nil && !session.scrubbing && !session.holding
    }

    private func dragBegan(_ translation: CGFloat) {
        guard allowsEpisodeDrag, !pageMoving else { return }
        pageMotion = PageMotion(origin: session.playID)
        dragChanged(translation)
    }

    private func dragChanged(_ translation: CGFloat) {
        guard allowsEpisodeDrag, dragging, pageMotion?.origin == session.playID else { return }
        dragOffset = EpisodePageSwipe.offset(for: translation, height: pageHeight,
                                             hasPrevious: session.index > 0,
                                             hasNext: session.index + 1 < session.detail.episodes.count)
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        guard dragging else { return }
        guard allowsEpisodeDrag, pageMotion?.origin == session.playID,
              let step = EpisodePageSwipe.step(translation: translation, velocity: velocity, height: pageHeight),
              session.detail.episodes.indices.contains(session.index + step) else {
            dragCancelled()
            return
        }
        settlePage(to: session.index + step, fromSwipe: true)
    }

    private func dragCancelled() {
        guard dragging else { return }
        settlePage(to: nil, fromSwipe: true)
    }

    private func resetEpisodePaging() {
        pageMotion = nil
        dragOffset = 0
    }

    private func slide(to target: Int) {
        guard detailSwipe == nil, !pageMoving, target != session.index, session.detail.episodes.indices.contains(target) else { return }
        if landscape || !inlineForeground { session.load(index: target); return }
        pageMotion = PageMotion(origin: session.playID)
        settlePage(to: target, fromSwipe: false)
    }

    private func settlePage(to target: Int?, fromSwipe: Bool) {
        guard let motion = pageMotion else { return }
        pageMotion?.settling = true
        pageMotion?.target = target
        let destination = target.map { $0 > session.index ? -pageHeight : pageHeight } ?? 0
        withAnimation(.easeOut(duration: reduceMotion ? 0 : (target == nil ? 0.22 : 0.28)), completionCriteria: .removed) {
            dragOffset = destination
        } completion: {
            guard pageMotion?.token == motion.token else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                resetEpisodePaging()
                if let target, session.playID == motion.origin, inlineForeground {
                    if fromSwipe { session.turnPage(to: target, from: motion.origin) }
                    else { session.load(index: target) }
                    if session.playID != motion.origin { pagingPosterTicket = session.playID }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 4) {
            Button(action: goBack) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "chevron.left").font(.body.weight(.medium))
                    if !landscape { episodeHeading(session.episode) }
                }
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel(landscape ? "退出全屏" : "关闭播放器")
                .accessibilityValue(landscape ? "" : "第 \(session.episode.index) 集")
                .accessibilityIdentifier(landscape ? "player.exitFullScreen" : "player.close")
            if landscape { dramaTitle; episodeHeading(session.episode) }
            Spacer(minLength: 6)
            Button { moreVisible = true } label: {
                AppControlIcon(name: "ellipsis")
            }.accessibilityLabel("更多").accessibilityIdentifier("player.more")
        }.buttonStyle(.plain).shadow(color: .black.opacity(0.55), radius: 2, y: 1)
    }

    private func episodeHeading(_ episode: Episode) -> some View {
        Text("第 \(episode.index) 集").font(.playbackHeading).monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }

    private var dramaTitle: some View {
        Button(action: openDetail) {
            HStack(spacing: 5) {
                Text(session.detail.drama.title).font(.playbackHeading).lineLimit(1)
                if !landscape { Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(session.detail.drama.title)，第 \(session.episode.index) 集")
            .accessibilityHint("打开短剧详情").accessibilityIdentifier("player.dramaTitle")
    }

    private func sideActions(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: PlaybackPictureLayout.Context.player.interactionSpacing))
        return layout {
            FollowDramaButton(seriesID: session.detail.drama.id, selected: library.isFavorite(session.detail.drama)) {
                library.toggleFavorite(session.detail.drama)
            }.accessibilityIdentifier("player.favorite")
            DiscussionControls { commentsVisible = true }
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
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle").font(.largeTitle)
            Text(message).font(.subheadline).multilineTextAlignment(.center).lineLimit(5)
            Button("重试", action: session.retry).buttonStyle(.borderedProminent).tint(Color(hex: 0xC94426))
        }.padding(25).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private func bottomBar(compact: Bool, dockInteractions: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 3) {
            if !landscape {
                if dockInteractions {
                    HStack(spacing: 8) {
                        dramaTitle
                        Spacer(minLength: 0)
                        sideActions(horizontal: true)
                    }
                } else {
                    dramaTitle.padding(.trailing, 68)
                }
            }
            if showingHint {
                Text("长按 2× · 纵滑锁定 · 横滑调进度").font(.caption2)
                    .foregroundStyle(.white.opacity(0.75)).accessibilityIdentifier("player.gestureHint")
            }
            HStack(spacing: 10) {
                Text(timeLabel(session.scrubbing ? session.previewPosition : session.position)).font(.caption.monospacedDigit()).frame(minWidth: 36)
                    .accessibilityIdentifier("player.elapsed")
                Slider(value: Binding(get: { session.scrubbing ? session.previewPosition : session.position }, set: { session.previewPosition = $0 }), in: 0...max(session.duration, 1), onEditingChanged: session.setSeeking).tint(session.app.appearance.accent).disabled(session.duration <= 0).accessibilityLabel("播放进度")
                Text(timeLabel(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).frame(minWidth: 36)
            }
            HStack(spacing: 8) {
                if landscape {
                    sideActions(horizontal: true)
                    Spacer(minLength: 8)
                }
                Button { episodesVisible = true } label: {
                    PlaybackEpisodeStrip(title: "选集", detail: "全 \(session.detail.episodes.count) 集")
                }.fixedSize(horizontal: landscape, vertical: false).accessibilityIdentifier("player.episodes")
            }.buttonStyle(.plain)
        }
    }

    private var speedLabel: String { String(format: "%g×", session.app.speed) }

}

private struct PlayerDetailArrival: UIViewControllerRepresentable {
    let arrived: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.arrived = arrived }

    final class Controller: UIViewController {
        var arrived: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            arrived?()
        }
    }
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
