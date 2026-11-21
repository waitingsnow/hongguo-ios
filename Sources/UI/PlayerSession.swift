import Foundation
import AVFoundation
import Combine
import UIKit

/// One drama's playback. A single `AVPlayer` lives for the whole session and episodes swap its item, so the picture
/// layer and 小窗播放 (picture in picture) stay attached while autoplay moves on, in the background as well.
/// The next episode is opened and its first seconds downloaded while the current one plays, so switching starts at once.
@MainActor
final class PlayerSession: ObservableObject {
    let detail: DramaDetail
    let app: AppModel
    let recordsLocalHistory: Bool
    @Published private(set) var index: Int
    @Published private(set) var playID = UUID()
    @Published private(set) var player: AVPlayer?
    @Published private(set) var preparing = false
    @Published private(set) var stage = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var buffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rendered = false
    @Published private(set) var holding = false
    @Published private(set) var speedLocked = false
    @Published private(set) var endMessage: String?
    @Published private(set) var sleepTimerLabel = "关闭"
    @Published private(set) var pausedBySleepTimer = false
    let didPausePlayback = PassthroughSubject<Void, Never>()
    /// The picture's display size; zero until the first video format is known.
    @Published private(set) var videoSize: CGSize = .zero
    /// The 清晰度 this episode is playing in.
    @Published private(set) var quality: VideoQuality
    private var finished = false
    @Published var scrubbing = false
    @Published var previewPosition: Double = 0
    private var requestTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var seasonTask: Task<Void, Never>?
    private var seasonOpening: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private let sleepClock = ContinuousClock()
    private var sleepDeadline: ContinuousClock.Instant?
    private var stopsAtEpisodeEnd = false
    @Published private(set) var transitionFrame: UIImage?
    private var currentEpisode: OpenEpisode?
    private var currentStream: ProgressivePlayback? { currentEpisode?.stream }
    var currentPlaybackItem: AVPlayerItem? { currentEpisode?.item }
    private var stagedEpisode: OpenEpisode?
    private var stagedItemObservation: NSKeyValueObservation?
    private var pendingItemEnd: UUID?
    /// The previous episode's stream stays open until the next item replaces it, so the layer never shows an empty player.
    private var retiringEpisode: OpenEpisode?
    private let lookahead: PlaybackLookahead
    private var handoff: FeedHandoff?
    private var periodic: Any?
    private var autoNextObservation: AnyCancellable?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var sessionNotifications: [NSObjectProtocol] = []
    private var stopped = false
    private var lastSave = Date.distantPast
    private var pausedByRequest = false
    private var resumeAfterInterruption = false
    /// Silent reloads from the current position after a playback failure, per episode.
    private var recoveries = 0
    private static let maximumRecoveries = 2
    /// Where the current item started, so the first advance of time counts as a shown frame.
    private var startPosition: Double = 0
    /// Set by the player screen: episode changes slide like a page instead of cutting. Cleared on stop to break the cycle.
    var onSlide: (@MainActor (Int) -> Void)?
    private let requestID: UUID
    private let initialPosition: Double
    private let accountToken: UUID
    var episode: Episode { detail.episodes[index] }

    init(request: PlaybackRequest, app: AppModel) {
        requestID = request.id
        detail = request.detail; index = request.index; initialPosition = request.position
        position = request.position; previewPosition = request.position
        recordsLocalHistory = request.recordsLocalHistory; self.app = app
        sleepDeadline = request.sleepDeadline
        handoff = request.handoff
        lookahead = request.handoff?.lookahead ?? PlaybackLookahead()
        quality = app.quality
        accountToken = AccountService.shared.playbackToken
        speedLocked = request.handoff?.speedLocked ?? false
        transitionFrame = request.handoff?.displayedFrame ?? PlaybackLookahead.frame(PlaybackTarget(detail, index: index, quality: quality))
        request.handoff?.displayedFrame = nil
    }

    func start() {
        guard !stopped else { return }
        autoNextObservation = app.$autoNext.dropFirst().sink { [weak self] enabled in
            self?.updateEndAction(autoNext: enabled)
            Task { @MainActor in self?.finishPendingItemEnd() }
        }
        sessionNotifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in _ = self?.refreshSleepTimer() }
        })
        if sleepDeadline != nil, sleepTimerTask == nil { scheduleSleepTimer() }
        guard !pausedBySleepTimer else { return }
        if let live = handoff?.live {
            handoff?.live = nil
            handoff = nil
            _ = makePlayer(live.player)
            install(episode: live.episode, startAt: initialPosition, ticket: playID)
        } else {
            let outgoingFrame = handoff == nil ? nil : transitionFrame
            handoff = nil
            load(index: index, startAt: initialPosition)
            if transitionFrame == nil { transitionFrame = outgoingFrame }
        }
    }

    func setSleepTimer(minutes: Int?) {
        guard !stopped else { return }
        if let minutes, minutes <= 0 { pauseForSleep(); return }
        clearSleepTimer()
        guard let minutes else { return }
        let seconds = min(Int64(minutes), Int64.max / 60) * 60
        sleepDeadline = sleepClock.now.advanced(by: .seconds(seconds))
        scheduleSleepTimer()
    }

    private func scheduleSleepTimer() {
        guard let nextUpdate = refreshSleepTimer() else { return }
        let clock = sleepClock
        sleepTimerTask = Task { [weak self] in
            var nextUpdate = nextUpdate
            while !Task.isCancelled {
                do { try await clock.sleep(until: nextUpdate) } catch { return }
                guard !Task.isCancelled, let update = self?.refreshSleepTimer() else { return }
                nextUpdate = update
            }
        }
    }

    func stopAtEpisodeEnd() {
        guard !stopped else { return }
        adoptQueuedEpisodeIfNeeded()
        if finished { pauseForSleep(); return }
        clearSleepTimer(stopAtEpisodeEnd: true)
        finishPendingItemEnd()
    }

    private func clearSleepTimer(stopAtEpisodeEnd: Bool = false) {
        sleepTimerTask?.cancel(); sleepTimerTask = nil
        sleepDeadline = nil; stopsAtEpisodeEnd = stopAtEpisodeEnd
        updateEndAction(autoNext: app.autoNext)
        let label = stopAtEpisodeEnd ? "本集结束后关闭" : "关闭"
        if sleepTimerLabel != label { sleepTimerLabel = label }
    }

    private func refreshSleepTimer() -> ContinuousClock.Instant? {
        guard let sleepDeadline else { return nil }
        let timeLeft = sleepClock.now.duration(to: sleepDeadline)
        guard timeLeft > .zero else { pauseForSleep(); return nil }
        let remaining = timeLeft.components
        let minutes = remaining.seconds / 60 + (remaining.seconds % 60 > 0 || remaining.attoseconds > 0 ? 1 : 0)
        let label = "\(minutes) 分钟后关闭"
        if sleepTimerLabel != label { sleepTimerLabel = label }
        return sleepDeadline.advanced(by: .seconds(-max(0, minutes - 1) * 60))
    }

    private func pauseIfSleepTimerExpired() -> Bool {
        guard let sleepDeadline, sleepClock.now >= sleepDeadline else { return false }
        pauseForSleep()
        return true
    }

    private func pauseForSleep() {
        adoptQueuedEpisodeIfNeeded()
        pausedBySleepTimer = true
        clearSleepTimer()
        resumeAfterInterruption = false; scrubbing = false
        cancelSeasonAdvance()
        cancelPreparation()
        frameTask?.cancel(); frameTask = nil
        handoff?.live?.player.pause()
        pause()
        buffering = false
        if let queue = player as? AVQueuePlayer { lookahead.stageNext(nil, on: queue) }
        setStagedEpisode(nil)
        lookahead.clear()
        finishPendingItemEnd()
        endMessage = "定时结束，已暂停播放"
        didPausePlayback.send()
    }

    func load(index target: Int, startAt: Double? = nil, recovering: Bool = false) {
        guard detail.episodes.indices.contains(target), !stopped, !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        adoptQueuedEpisodeIfNeeded()
        if target != index, stopsAtEpisodeEnd { clearSleepTimer() }
        cancelSeasonAdvance()
        if !recovering { saveProgress(flush: true) }
        requestTask?.cancel()
        let nextEpisode = detail.episodes[target]
        let chosen = app.quality
        let destination = PlaybackTarget(detail, index: target, quality: chosen)
        let opening = lookahead.claim(destination)
        transitionFrame = PlaybackLookahead.frame(destination)
        detachItem()
        pausedByRequest = false
        if !recovering { recoveries = 0 }
        index = target; playID = UUID(); quality = chosen
        let ticket = playID
        frameTask?.cancel()
        if transitionFrame == nil {
            frameTask = Task { [weak self] in
                guard await PlaybackLookahead.restoreFrame(destination), let self, self.playID == ticket, !self.rendered else { return }
                self.transitionFrame = PlaybackLookahead.frame(destination)
            }
        }
        let saved = startAt ?? (recordsLocalHistory ? app.library.progress(for: detail.drama.id).flatMap { $0.episodeID == nextEpisode.id ? $0.position : nil } : nil) ?? 0
        position = saved; duration = 0; previewPosition = saved
        preparing = true; stage = "正在准备播放"; progress = 0; error = nil
        rendered = false; endMessage = nil; holding = false; videoSize = .zero; scrubbing = false; finished = false
        requestTask = Task { [weak self] in
            var attempt = 0
            while true {
                do {
                    guard let self, !Task.isCancelled, !self.pauseIfSleepTimerExpired() else { opening.cancel(); return }
                    let task = attempt == 0 ? opening : self.lookahead.claim(destination)
                    let episode = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                    guard self.playID == ticket, !self.stopped, !Task.isCancelled else { return }
                    self.install(episode: episode, startAt: saved, ticket: ticket)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.playID == ticket, !self.stopped else { return }
                    // One quiet second attempt: a dropped connection or an expired address usually works right away.
                    if attempt == 0 {
                        attempt += 1; self.stage = "正在重新连接"
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        guard self.playID == ticket, !self.stopped, !Task.isCancelled else { return }
                        continue
                    }
                    self.preparing = false; self.error = friendlyError(error); self.stage = "准备失败"
                    return
                }
            }
        }
    }

    private func makePlayer(_ player: AVPlayer = AVQueuePlayer()) -> AVPlayer {
        player.actionAtItemEnd = .pause
        // AVPlayer waits for enough data and then resumes by itself. Without this a slow range stalled playback and
        // left it paused until the user tapped.
        player.automaticallyWaitsToMinimizeStalling = true
        playerObservations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.adoptQueuedEpisodeIfNeeded()
                guard !self.pauseIfSleepTimerExpired() else { return }
                if self.pausedBySleepTimer {
                    if player.timeControlStatus != .paused || player.rate != 0 { player.pause() }
                    return
                }
                self.isPlaying = player.timeControlStatus == .playing
                self.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if !self.isPlaying { self.endHold() }
                if !self.preparing, self.rendered { self.prepareUpcomingIfReady() }
            }
        })
        playerObservations.append(player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.adoptQueuedEpisodeIfNeeded()
                _ = self.pauseIfSleepTimerExpired()
                self.finishPendingItemEnd()
            }
        })
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sessionNotifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self?.interrupted(began: type == .began, shouldResume: options.contains(.shouldResume)) }
        })
        self.player = player
        return player
    }

    private func install(episode: OpenEpisode, startAt: Double, ticket: UUID) {
        guard !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = self.player ?? makePlayer()
        let item = episode.item
        currentEpisode = episode; episode.stream.resume()
        preparing = false; buffering = true; startPosition = max(0, startAt)
        observeItem(item, ticket: ticket)
        let continuing = player.currentItem === item
        if !continuing {
            if let queue = player as? AVQueuePlayer, queue.items().dropFirst().first === item {
                queue.advanceToNextItem()
            } else {
                if let queue = player as? AVQueuePlayer { lookahead.stageNext(nil, on: queue) }
                player.replaceCurrentItem(with: item)
            }
        }
        item.preferredForwardBufferDuration = 0
        retiringEpisode = nil
        player.defaultRate = playbackSpeed
        if startAt > 0.5 && !continuing {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playID == ticket, !self.stopped,
                          !self.pauseIfSleepTimerExpired(), !self.pausedBySleepTimer else { return }
                    self.player?.playImmediately(atRate: self.playbackSpeed)
                }
            }
        } else { player.playImmediately(atRate: playbackSpeed) }
    }

    private func observeItem(_ item: AVPlayerItem, ticket: UUID) {
        itemObservations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.playID == ticket else { return }
                if item.status == .failed { self.failed("视频播放失败，请重试或选择其他集。") }
                let length = item.duration.seconds
                if length.isFinite && length > 0 { self.duration = length }
            }
        })
        itemObservations.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in guard let self, self.playID == ticket, size.width > 0, size.height > 0 else { return }; self.videoSize = size }
        })
        itemNotifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.itemDidEnd(ticket: ticket) } })
        itemNotifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playID == ticket else { return }; self.failed("视频播放中断，请重试或选择其他集。") } })
    }

    private func tick() {
        adoptQueuedEpisodeIfNeeded()
        finishPendingItemEnd()
        guard let player, let item = currentPlaybackItem, player.currentItem === item,
              !stopped, !preparing, !finished else { return }
        let now = player.currentTime().seconds
        if now.isFinite { position = max(0, now) }
        let total = item.duration.seconds
        if total.isFinite && total > 0 { duration = total }
        guard !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        // The layer reports its first frame; time moving forward is the backup for a swapped item that kept it set.
        if !rendered, player.timeControlStatus == .playing, now.isFinite, now > startPosition + 0.2 { firstFrame(ticket: playID) }
        if Date().timeIntervalSince(lastSave) > 5 { saveProgress() }
        prepareUpcomingIfReady()
    }

    /// A failed item reloads from where it was, quietly, a couple of times before the error is shown.
    private func failed(_ message: String) {
        guard !stopped, !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        if recoveries < Self.maximumRecoveries {
            recoveries += 1
            let resumeAt = position
            load(index: index, startAt: resumeAt, recovering: true)
            return
        }
        error = message; buffering = false; isPlaying = false; player?.pause()
        updateEndAction(autoNext: app.autoNext)
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        guard !stopped, !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        if began {
            resumeAfterInterruption = isPlaying
            pause()
            if resumeAfterInterruption { didPausePlayback.send() }
        } else if shouldResume, resumeAfterInterruption, !finished, error == nil {
            resumeAfterInterruption = false
            pausedByRequest = false
            currentStream?.resume(); player?.playImmediately(atRate: playbackSpeed)
        }
    }

    func firstFrame(ticket: UUID) {
        guard ticket == playID, !rendered, let player, let item = currentPlaybackItem, player.currentItem === item,
              !preparing, !stopped else { return }
        rendered = true; buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if let episode = currentEpisode {
            let target = PlaybackTarget(detail, index: index, quality: quality)
            frameTask?.cancel()
            frameTask = Task(priority: .utility) { await PlaybackLookahead.capture(episode, target: target) }
        }
        if recordsLocalHistory {
            let value = player.currentTime().seconds
            app.library.record(drama: detail.drama, episode: episode, position: value.isFinite ? max(0, value) : position)
            app.library.flush()
        }
    }

    func firstFrame(for item: AVPlayerItem) -> UUID? {
        adoptQueuedEpisodeIfNeeded()
        guard currentPlaybackItem === item, player?.currentItem === item else { return nil }
        firstFrame(ticket: playID)
        return playID
    }

    func toggle() {
        guard !stopped, !pauseIfSleepTimerExpired() else { return }
        adoptQueuedEpisodeIfNeeded()
        if pausedBySleepTimer {
            pausedBySleepTimer = false; endMessage = nil
            if finished || currentEpisode == nil || error != nil || quality != app.quality {
                retry()
            } else {
                pausedByRequest = false
                currentStream?.resume(); player?.playImmediately(atRate: playbackSpeed)
            }
        } else if finished {
            load(index: index, startAt: 0)
        } else if isPlaying || (player?.rate ?? 0) > 0 {
            pause()
            didPausePlayback.send()
        } else {
            pausedByRequest = false
            endHold(); endMessage = nil; currentStream?.resume(); player?.playImmediately(atRate: playbackSpeed)
        }
    }
    func pause() {
        adoptQueuedEpisodeIfNeeded()
        pausedByRequest = true
        endHold(); player?.pause(); currentStream?.pause(); lookahead.pause(); isPlaying = false; saveProgress(flush: true)
    }
    /// A drag across the full width moves through the whole episode, or through this much of a longer one.
    nonisolated static let dragSeekSpan: Double = 180
    /// Where a sideways drag of `fraction` of the width (negative to the left) lands from `start`, held a second short of the end.
    nonisolated static func dragSeekTarget(start: Double, duration: Double, fraction: Double) -> Double {
        guard duration > 0 else { return start }
        return min(max(0, start + min(duration, dragSeekSpan) * fraction), max(0, duration - 1))
    }
    /// A sideways drag across the picture previews like the slider; releasing seeks only when the position really moved.
    func beginDragSeek() -> Bool {
        // A seek starts from a hold, so a 2× hold in progress is ended (by setSeeking) rather than refused.
        guard player != nil, rendered, !scrubbing, duration > 0, error == nil else { return false }
        setSeeking(true); return scrubbing
    }
    func endDragSeek(from start: Double, commit: Bool) {
        guard scrubbing else { return }
        if commit, abs(previewPosition - start) > 0.2 { setSeeking(false) } else { scrubbing = false }
    }
    var playbackSpeed: Float { holding || speedLocked ? 2 : app.speed }
    var canLockSpeed: Bool { isPlaying && rendered && !scrubbing && !speedLocked }

    func setSpeed(_ speed: Float) {
        app.speed = speed
        holding = false
        speedLocked = false
        applyPlaybackSpeed()
    }

    func lockSpeed() {
        guard canLockSpeed else { return }
        speedLocked = true
        holding = false
        applyPlaybackSpeed()
    }

    func unlockSpeed() {
        guard speedLocked else { return }
        speedLocked = false
        applyPlaybackSpeed()
    }
    /// Switches 清晰度 for this and later episodes, continuing from the same position.
    func setQuality(_ value: VideoQuality) {
        app.quality = value
        guard value != quality, !stopped else { return }
        load(index: index, startAt: position)
    }
    func beginHold() { guard canLockSpeed, !holding else { return }; holding = true; applyPlaybackSpeed(); Haptics.holdSpeedBegan() }
    func endHold() { guard holding else { return }; holding = false; applyPlaybackSpeed() }

    private func applyPlaybackSpeed() {
        guard let player else { return }
        let rate = playbackSpeed
        player.defaultRate = rate
        if player.timeControlStatus != .paused, player.rate != rate { player.rate = rate }
    }
    func setSeeking(_ editing: Bool) {
        guard !stopped, !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        endHold()
        if editing { previewPosition = position; scrubbing = true }
        else {
            cancelSeasonAdvance()
            scrubbing = false; finished = false; endMessage = nil
            // A paused stream would hold the seek's reads until play; the new picture should show right away.
            currentStream?.resume()
            player?.seek(to: CMTime(seconds: max(0, previewPosition), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            position = previewPosition; saveProgress()
        }
    }
    func next() { guard index + 1 < detail.episodes.count else { endMessage = "已到最后一集"; return }; go(to: index + 1) }
    func previous() { guard index > 0 else { endMessage = "已经是第一集"; return }; go(to: index - 1) }
    /// Buttons, autoplay and the episode sheet all switch through here, so they slide like a user swipe when a screen is attached.
    func go(to target: Int) {
        guard detail.episodes.indices.contains(target), !stopped, !pauseIfSleepTimerExpired() else { return }
        adoptQueuedEpisodeIfNeeded()
        if pausedBySleepTimer {
            if target == index { toggle() }
            else {
                pausedBySleepTimer = false
                load(index: target, startAt: 0)
            }
            return
        }
        guard target != index else { return }
        if let onSlide { onSlide(target) } else { load(index: target, startAt: 0) }
    }
    func retry() {
        guard !stopped, !pauseIfSleepTimerExpired() else { return }
        pausedBySleepTimer = false
        recoveries = 0; load(index: index, startAt: position)
    }
    func suspend() {
        guard !stopped, !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        pause()
        if let queue = player as? AVQueuePlayer { lookahead.stageNext(nil, on: queue) }
        setStagedEpisode(nil)
        updateEndAction(autoNext: app.autoNext)
        lookahead.clear()
        finishPendingItemEnd()
        if preparing {
            cancelPreparation()
            error = "播放准备已暂停，回到前台后可重试。"
        }
    }

    private func cancelPreparation() {
        guard preparing else { return }
        requestTask?.cancel(); requestTask = nil; playID = UUID(); preparing = false
    }
    /// 下一集整集预加载 changed: what is already prepared stays, a new preparation follows the new setting.
    func preferencesChanged() { prepareUpcomingIfReady() }

    private func recordCompletion() {
        let itemDuration = currentPlaybackItem?.duration.seconds ?? 0
        let total = itemDuration.isFinite && itemDuration > 0 ? itemDuration : duration
        if rendered { AccountService.shared.observePlayback(drama: detail.drama, episode: episode, position: total, duration: total, token: accountToken, force: true) }
        if recordsLocalHistory { app.library.updatePosition(dramaID: detail.drama.id, episodeID: episode.id, position: 0); app.library.flush() }
    }

    @discardableResult
    private func adoptQueuedEpisodeIfNeeded() -> Bool {
        guard let player, let next = stagedEpisode, player.currentItem === next.item,
              detail.episodes.indices.contains(index + 1), !stopped, !preparing, !finished else { return false }
        let target = PlaybackTarget(detail, index: index + 1, quality: quality)
        pendingItemEnd = nil
        setStagedEpisode(nil)
        updateEndAction(autoNext: app.autoNext)
        lookahead.consumePrepared(next, for: target)
        recordCompletion()
        removeItemObservers()
        frameTask?.cancel(); frameTask = nil
        endHold()
        currentEpisode = next
        next.item.preferredForwardBufferDuration = 0
        transitionFrame = nil; rendered = false; scrubbing = false
        let now = player.currentTime().seconds
        position = now.isFinite ? max(0, now) : 0
        startPosition = 0; previewPosition = position; duration = 0; videoSize = .zero
        error = nil; endMessage = nil; recoveries = 0
        isPlaying = player.timeControlStatus == .playing
        buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        index = target.index; playID = UUID()
        observeItem(next.item, ticket: playID)
        return true
    }

    private func itemDidEnd(ticket: UUID) {
        guard playID == ticket, !stopped, !finished, !adoptQueuedEpisodeIfNeeded() else { return }
        pendingItemEnd = ticket
        finishPendingItemEnd()
    }

    private func finishPendingItemEnd() {
        guard let ticket = pendingItemEnd, playID == ticket, !stopped, !finished,
              !adoptQueuedEpisodeIfNeeded() else { return }
        if let queue = player as? AVQueuePlayer, queue.actionAtItemEnd == .advance,
           let next = stagedEpisode?.item, next.status != .failed,
           queue.items().contains(where: { $0 === next }) { return }
        guard !adoptQueuedEpisodeIfNeeded() else { return }
        pendingItemEnd = nil
        recordCompletion()
        endHold(); isPlaying = false; position = 0; finished = true
        updateEndAction(autoNext: app.autoNext)
        if stopsAtEpisodeEnd { pauseForSleep(); return }
        guard !pauseIfSleepTimerExpired(), !pausedBySleepTimer else { return }
        if index + 1 < detail.episodes.count { if app.autoNext && !pausedByRequest { load(index: index + 1, startAt: 0) } else { endMessage = "本集已播完，上滑观看下一集" } }
        else {
            endMessage = "已播完最后一集"
            seasonTask = Task { [weak self] in await self?.advanceSeason() }
        }
    }

    /// After the last episode, continues with the next season when it is on line and autoplay is on.
    private func advanceSeason() async {
        guard canAdvanceSeason(),
              let works = try? await DramaAPI.shared.related(id: detail.drama.id),
              canAdvanceSeason(),
              let next = RelatedWorks.nextSeason(works) else { return }
        if next.upcoming {
            let release = (try? await DramaAPI.shared.upcomingRelease(id: next.id, title: next.drama.title)) ?? ""
            guard canAdvanceSeason() else { return }
            endMessage = "已播完最后一集，\(next.season)\(release.isEmpty ? "待上线" : release)，可在详情页预约"
        } else if app.autoNext, app.openingDramaID == nil {
            seasonOpening = app.openPlayback(next.drama, canPresent: { [weak self] in
                guard let self else { return false }
                return self.canAdvanceSeason() && self.app.autoNext
            }, sleepDeadline: { [weak self] in self?.sleepDeadline })
        } else {
            endMessage = "已播完最后一集，\(next.season)可在详情页观看"
        }
    }

    private func canAdvanceSeason() -> Bool {
        !Task.isCancelled && !stopped && finished && !pauseIfSleepTimerExpired()
            && !pausedBySleepTimer && app.playback?.id == requestID
    }

    private func cancelSeasonAdvance() {
        seasonTask?.cancel(); seasonTask = nil
        seasonOpening?.cancel(); seasonOpening = nil
    }

    /// A few seconds into an episode, the next one is opened and its start downloaded (the whole episode when
    /// 下一集整集预加载 is on), so autoplay, a swipe or the next button start it without waiting.
    private func prepareUpcomingIfReady() {
        adoptQueuedEpisodeIfNeeded()
        guard rendered, !stopped, !pausedBySleepTimer, !scrubbing, let player else { lookahead.pause(); return }
        let targets = detail.episodes.indices.dropFirst(index + 1).prefix(2).map { PlaybackTarget(detail, index: $0, quality: quality) }
        let depth = PlaybackLookahead.depth(player: player, speed: player.rate)
        lookahead.update(targets, depth: depth, wholeFirst: app.preloadNext)
        if let queue = player as? AVQueuePlayer, !finished, player.timeControlStatus != .paused,
           player.currentItem === currentPlaybackItem {
            let next = lookahead.stageNext(targets.first, on: queue)
            if !adoptQueuedEpisodeIfNeeded() { setStagedEpisode(next) }
            updateEndAction(autoNext: app.autoNext)
        }
    }

    private func setStagedEpisode(_ episode: OpenEpisode?) {
        guard stagedEpisode !== episode else { return }
        stagedEpisode = episode
        stagedItemObservation = episode?.item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.stagedEpisode?.item === item, item.status == .failed else { return }
                self.updateEndAction(autoNext: self.app.autoNext)
                self.finishPendingItemEnd()
            }
        }
    }

    private func updateEndAction(autoNext: Bool) {
        guard let player else { return }
        let shouldAdvance = autoNext && stagedEpisode != nil && stagedEpisode?.item.status != .failed
            && !stopsAtEpisodeEnd && !pausedBySleepTimer
            && !stopped && !finished && error == nil
        let action: AVPlayer.ActionAtItemEnd = shouldAdvance ? .advance : .pause
        if player.actionAtItemEnd != action { player.actionAtItemEnd = action }
    }

    private func saveProgress(flush: Bool = false) {
        guard rendered, !finished, let item = currentPlaybackItem, player?.currentItem === item else { return }
        let value = player?.currentTime().seconds ?? position
        let current = value.isFinite ? max(0, value) : position
        if recordsLocalHistory {
            app.library.updatePosition(dramaID: detail.drama.id, episodeID: episode.id, position: current)
            if flush { app.library.flush() }
        }
        AccountService.shared.observePlayback(drama: detail.drama, episode: episode, position: current, duration: duration, token: accountToken, force: flush)
        lastSave = Date()
    }

    /// Lets go of the current item's observers and keeps the player and its last picture until the next item arrives.
    private func detachItem() {
        pendingItemEnd = nil
        setStagedEpisode(nil)
        updateEndAction(autoNext: app.autoNext)
        endHold(); player?.pause()
        removeItemObservers()
        isPlaying = false; buffering = false
        if let currentEpisode {
            retiringEpisode = currentEpisode
            self.currentEpisode = nil
        }
    }

    private func removeItemObservers() {
        itemObservations.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
    }

    func stop() {
        guard !stopped else { return }
        adoptQueuedEpisodeIfNeeded()
        saveProgress(flush: true); stopped = true; onSlide = nil
        autoNextObservation = nil
        clearSleepTimer()
        cancelSeasonAdvance()
        resumeAfterInterruption = false; preparing = false; scrubbing = false; pausedBySleepTimer = false
        handoff?.live?.player.pause(); handoff = nil
        requestTask?.cancel(); requestTask = nil; lookahead.clear(); playID = UUID()
        frameTask?.cancel(); frameTask = nil
        detachItem()
        if let periodic, let player { player.removeTimeObserver(periodic) }; periodic = nil
        playerObservations.removeAll(); sessionNotifications.forEach { NotificationCenter.default.removeObserver($0) }; sessionNotifications.removeAll()
        if let queue = player as? AVQueuePlayer { queue.removeAllItems() } else { player?.replaceCurrentItem(with: nil) }
        player = nil
        retiringEpisode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
