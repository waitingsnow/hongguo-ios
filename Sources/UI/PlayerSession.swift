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
    @Published private(set) var transitionFrame: UIImage?
    private var currentEpisode: OpenEpisode?
    private var currentStream: ProgressivePlayback? { currentEpisode?.stream }
    /// The previous episode's stream stays open until the next item replaces it, so the layer never shows an empty player.
    private var retiringEpisode: OpenEpisode?
    private let lookahead: PlaybackLookahead
    private var handoff: FeedHandoff?
    private var periodic: Any?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var sessionNotifications: [NSObjectProtocol] = []
    private var stopped = false
    private var lastSave = Date.distantPast
    private var resumeAfterGesture = false
    private var resumeAfterInterruption = false
    /// Silent reloads from the current position after a playback failure, per episode.
    private var recoveries = 0
    private static let maximumRecoveries = 2
    /// Where the current item started, so the first advance of time counts as a shown frame.
    private var startPosition: Double = 0
    /// Set by the player screen: episode changes slide like a page instead of cutting. Cleared on stop to break the cycle.
    var onSlide: (@MainActor (Int) -> Void)?
    private let initialPosition: Double
    private let accountToken: UUID
    var episode: Episode { detail.episodes[index] }

    init(request: PlaybackRequest, app: AppModel) {
        detail = request.detail; index = request.index; initialPosition = request.position
        recordsLocalHistory = request.recordsLocalHistory; self.app = app
        handoff = request.handoff
        lookahead = request.handoff?.lookahead ?? PlaybackLookahead()
        quality = app.quality
        accountToken = AccountService.shared.playbackToken
        speedLocked = request.handoff?.speedLocked ?? false
        transitionFrame = request.handoff?.displayedFrame ?? PlaybackLookahead.frame(PlaybackTarget(detail, index: index, quality: quality))
        request.handoff?.displayedFrame = nil
    }

    func start() {
        stopped = false
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

    func load(index target: Int, startAt: Double? = nil, recovering: Bool = false) {
        guard detail.episodes.indices.contains(target), !stopped else { return }
        if !recovering { saveProgress(flush: true) }
        requestTask?.cancel()
        let nextEpisode = detail.episodes[target]
        let chosen = app.quality
        let destination = PlaybackTarget(detail, index: target, quality: chosen)
        let opening = lookahead.claim(destination)
        transitionFrame = PlaybackLookahead.frame(destination)
        detachItem()
        if !recovering { recoveries = 0 }
        index = target; playID = UUID(); resumeAfterGesture = false; quality = chosen
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
                    guard let self, !Task.isCancelled else { opening.cancel(); return }
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
                self.isPlaying = player.timeControlStatus == .playing
                self.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if !self.isPlaying { self.endHold() }
                if !self.preparing, self.rendered { self.prepareUpcomingIfReady() }
            }
        })
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = self.player ?? makePlayer()
        let item = episode.item
        currentEpisode = episode; episode.stream.resume()
        preparing = false; buffering = true; startPosition = max(0, startAt)
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
        itemNotifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playID == ticket else { return }; self.ended() } })
        itemNotifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playID == ticket else { return }; self.failed("视频播放中断，请重试或选择其他集。") } })
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
                Task { @MainActor in guard let self, self.playID == ticket, !self.stopped else { return }; self.player?.playImmediately(atRate: self.playbackSpeed) }
            }
        } else { player.playImmediately(atRate: playbackSpeed) }
    }

    private func tick(_ time: CMTime) {
        guard let player, !stopped, !preparing, currentStream != nil else { return }
        let now = time.seconds
        if now.isFinite { position = max(0, now) }
        let total = player.currentItem?.duration.seconds ?? 0
        if total.isFinite && total > 0 { duration = total }
        // The layer reports its first frame; time moving forward is the backup for a swapped item that kept it set.
        if !rendered, player.timeControlStatus == .playing, now.isFinite, now > startPosition + 0.2 { firstFrame(ticket: playID) }
        if Date().timeIntervalSince(lastSave) > 5 { saveProgress() }
        prepareUpcomingIfReady()
    }

    /// A failed item reloads from where it was, quietly, a couple of times before the error is shown.
    private func failed(_ message: String) {
        guard !stopped else { return }
        if recoveries < Self.maximumRecoveries {
            recoveries += 1
            let resumeAt = position
            load(index: index, startAt: resumeAt, recovering: true)
            return
        }
        error = message; buffering = false; isPlaying = false; player?.pause()
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
            pause()
            if resumeAfterInterruption { didPausePlayback.send() }
        } else if shouldResume, resumeAfterInterruption, !stopped, !finished, error == nil {
            resumeAfterInterruption = false
            currentStream?.resume(); player?.playImmediately(atRate: playbackSpeed)
        }
    }

    func firstFrame(ticket: UUID) {
        guard ticket == playID, !rendered, let player, player.currentItem != nil, !preparing, !stopped else { return }
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

    func toggle() {
        if finished {
            load(index: index, startAt: 0)
        } else if isPlaying || (player?.rate ?? 0) > 0 {
            pause()
            didPausePlayback.send()
        } else {
            endHold(); endMessage = nil; currentStream?.resume(); player?.playImmediately(atRate: playbackSpeed)
        }
    }
    func pause() { endHold(); player?.pause(); currentStream?.pause(); lookahead.pause(); isPlaying = false; saveProgress(flush: true) }
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
        setSeeking(true); return true
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
        endHold()
        if editing { previewPosition = position; scrubbing = true }
        else {
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
        guard detail.episodes.indices.contains(target), target != index, !stopped else { return }
        if let onSlide { onSlide(target) } else { load(index: target, startAt: 0) }
    }
    /// A page drag or slide pauses the picture without changing the user's pause intent; coming back to the same episode resumes it.
    func holdForGesture() {
        endHold()
        if !resumeAfterGesture { resumeAfterGesture = isPlaying || (player?.rate ?? 0) > 0 }
        player?.pause()
    }
    func releaseGesture() {
        let resume = resumeAfterGesture; resumeAfterGesture = false
        guard resume, !stopped, !finished, error == nil, let player else { return }
        endMessage = nil; player.playImmediately(atRate: playbackSpeed)
    }
    func retry() { recoveries = 0; load(index: index, startAt: position) }
    func suspend() {
        resumeAfterGesture = false; pause(); saveProgress(flush: true); lookahead.clear()
        if preparing { requestTask?.cancel(); playID = UUID(); preparing = false; error = "播放准备已暂停，回到前台后可重试。" }
    }
    /// 下一集整集预加载 changed: what is already prepared stays, a new preparation follows the new setting.
    func preferencesChanged() { prepareUpcomingIfReady() }

    private func ended() {
        if rendered { AccountService.shared.observePlayback(drama: detail.drama, episode: episode, position: duration, duration: duration, token: accountToken, force: true) }
        endHold(); isPlaying = false; position = 0; finished = true
        if recordsLocalHistory { app.library.updatePosition(dramaID: detail.drama.id, episodeID: episode.id, position: 0); app.library.flush() }
        if index + 1 < detail.episodes.count { if app.autoNext { load(index: index + 1, startAt: 0) } else { endMessage = "本集已播完，上滑观看下一集" } }
        else { endMessage = "已播完最后一集"; Task { await advanceSeason() } }
    }

    /// After the last episode, continues with the next season when it is on line and autoplay is on.
    private func advanceSeason() async {
        guard let works = try? await DramaAPI.shared.related(id: detail.drama.id), let next = RelatedWorks.nextSeason(works), !stopped, finished else { return }
        if next.upcoming {
            let release = (try? await DramaAPI.shared.upcomingRelease(id: next.id, title: next.drama.title)) ?? ""
            guard !stopped, finished else { return }
            endMessage = "已播完最后一集，\(next.season)\(release.isEmpty ? "待上线" : release)，可在详情页预约"
        }
        else if app.autoNext { app.play(next.drama) }
        else { endMessage = "已播完最后一集，\(next.season)可在详情页观看" }
    }

    /// A few seconds into an episode, the next one is opened and its start downloaded (the whole episode when
    /// 下一集整集预加载 is on), so autoplay, a swipe or the next button start it without waiting.
    private func prepareUpcomingIfReady() {
        guard rendered, !stopped, !scrubbing, let player else { lookahead.pause(); return }
        let targets = detail.episodes.indices.dropFirst(index + 1).prefix(2).map { PlaybackTarget(detail, index: $0, quality: quality) }
        let depth = PlaybackLookahead.depth(player: player, speed: player.rate)
        lookahead.update(targets, depth: depth, wholeFirst: app.preloadNext)
        if let queue = player as? AVQueuePlayer, !finished, player.timeControlStatus != .paused {
            lookahead.stageNext(depth > 0 ? targets.first : nil, on: queue)
        }
    }

    private func saveProgress(flush: Bool = false) {
        guard rendered, !finished else { return }
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
        endHold(); player?.pause()
        itemObservations.removeAll(); itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }; itemNotifications.removeAll()
        isPlaying = false; buffering = false
        if let currentEpisode {
            retiringEpisode = currentEpisode
            self.currentEpisode = nil
        }
    }

    func stop() {
        guard !stopped else { return }
        saveProgress(flush: true); stopped = true; onSlide = nil; resumeAfterGesture = false
        requestTask?.cancel(); requestTask = nil; lookahead.clear(); playID = UUID()
        frameTask?.cancel(); frameTask = nil
        detachItem()
        if let periodic, let player { player.removeTimeObserver(periodic) }; periodic = nil
        playerObservations.removeAll(); sessionNotifications.forEach { NotificationCenter.default.removeObserver($0) }; sessionNotifications.removeAll()
        player?.replaceCurrentItem(with: nil); player = nil
        retiringEpisode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
