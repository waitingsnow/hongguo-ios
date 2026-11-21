import Foundation
import AVFoundation
import Combine
import UIKit
import SwiftUI

/// A light tap felt when long-press 2× starts, in the feed and the full player.
@MainActor enum Haptics {
    static func holdSpeedBegan() { let generator = UIImpactFeedbackGenerator(style: .medium); generator.prepare(); generator.impactOccurred() }
}

@MainActor
final class FeedHandoff {
    let lookahead: PlaybackLookahead
    let speedLocked: Bool
    var displayedFrame: UIImage?
    var live: (player: AVPlayer, episode: OpenEpisode)?

    init(lookahead: PlaybackLookahead, live: (AVPlayer, OpenEpisode)?, speedLocked: Bool) {
        self.lookahead = lookahead
        self.live = live
        self.speedLocked = speedLocked
    }
}

@MainActor
final class FeedPreview: ObservableObject {
    @Published private(set) var dramaID: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var rendered = false
    @Published private(set) var paused = false
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var awaitingHandoff = false
    private var pendingPresentation: ((PlaybackRequest) -> Void)?
    @Published private(set) var holding = false
    @Published private(set) var speedLocked = false
    private var episode: OpenEpisode?
    var detail: DramaDetail? { episode?.detail }
    private var quality: VideoQuality = .p1080
    private var speed: Float = 1
    private var following: [Drama] = []
    private var lookahead: PlaybackLookahead
    init(lookahead: PlaybackLookahead? = nil) { self.lookahead = lookahead ?? PlaybackLookahead() }
    private var task: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private weak var layerHost: PlayerLayerHost?
    private var ticket = UUID()
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var periodic: Any?
    private var gestureSeekID = UUID()
    var position: Double { guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }; return max(0, seconds) }
    var playbackSpeed: Float { holding || speedLocked ? 2 : speed }

    func play(_ drama: Drama, quality: VideoQuality, speed: Float, following: [Drama]) {
        let rateChanged = self.speed != speed
        self.speed = speed
        self.following = Array(following.prefix(2))
        if dramaID == drama.id, self.quality == quality, !failed {
            if rateChanged && !paused && !ended { player?.defaultRate = playbackSpeed; player?.rate = playbackSpeed }
            schedule()
            return
        }
        let target = PlaybackTarget(drama, quality: quality)
        let opening = lookahead.claim(target)
        resetPlayer()
        self.quality = quality
        dramaID = drama.id
        let ticket = self.ticket
        lookahead.frameAvailable = { [weak self] in self?.objectWillChange.send() }
        task = Task { [weak self] in
            do {
                let episode = try await withTaskCancellationHandler(operation: { try await opening.value }, onCancel: { opening.cancel() })
                guard let self, self.ticket == ticket, !Task.isCancelled else { return }
                self.episode = episode
                self.install(episode.item, ticket: ticket)
                if let present = self.pendingPresentation, let request = self.handoff(index: 0) { present(request) }
            } catch {
                guard let self, self.ticket == ticket, !Task.isCancelled else { return }
                self.pendingPresentation = nil
                self.awaitingHandoff = false
                self.failed = true
            }
        }
    }

    private func install(_ item: AVPlayerItem, ticket: UUID) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVQueuePlayer(items: [item])
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in guard let self, self.ticket == ticket, item.status == .failed else { return }; self.failed = true }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in guard let self, self.ticket == ticket else { return }; self.schedule() }
        })
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.ticket == ticket else { return }; self.schedule() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.ticket == ticket else { return }; self.holding = false; self.ended = true; self.paused = true }
        }
        self.player = player
        player.defaultRate = playbackSpeed
        player.playImmediately(atRate: playbackSpeed)
    }

    private func schedule() {
        guard rendered, !ended, !paused, let player, let detail else { return }
        var targets = following.map { PlaybackTarget($0, quality: quality) }
        if detail.episodes.count > 1 {
            let remaining = (player.currentItem?.duration.seconds ?? .infinity) - position
            targets.insert(PlaybackTarget(detail, index: 1, quality: quality), at: remaining < 8 * Double(playbackSpeed) ? 0 : min(1, targets.count))
        }
        lookahead.update(targets, depth: PlaybackLookahead.depth(player: player, speed: playbackSpeed))
    }

    func markRendered(_ player: AVPlayer, host: PlayerLayerHost? = nil) {
        if self.player === player, let host { layerHost = host }
        guard self.player === player, !rendered, let episode else { return }
        rendered = true
        schedule()
        let target = PlaybackTarget(episode.detail, index: 0, quality: quality)
        frameTask = Task(priority: .utility) { await PlaybackLookahead.capture(episode, target: target) }
    }

    func firstFrame(for drama: Drama, quality: VideoQuality) -> UIImage? {
        PlaybackLookahead.frame(PlaybackTarget(drama, quality: quality))
    }

    func restoreFirstFrame(for drama: Drama, quality: VideoQuality) async {
        let target = PlaybackTarget(drama, quality: quality)
        guard PlaybackLookahead.frame(target) == nil else { return }
        if await PlaybackLookahead.restoreFrame(target) { objectWillChange.send() }
    }

    func handoff(index: Int) -> PlaybackRequest? {
        guard let episode, episode.detail.episodes.indices.contains(index), let player else { return nil }
        let live = index == 0 && !ended
        let handoff = FeedHandoff(lookahead: lookahead, live: live ? (player, episode) : nil, speedLocked: speedLocked)
        if live { handoff.displayedFrame = layerHost?.snapshotDisplayedFrame() }
        else { handoff.displayedFrame = PlaybackLookahead.frame(PlaybackTarget(episode.detail, index: index, quality: quality)) ?? layerHost?.snapshotDisplayedFrame() }
        let request = PlaybackRequest(detail: episode.detail, index: index, position: live ? position : 0, recordsLocalHistory: true, handoff: handoff)
        lookahead.frameAvailable = nil
        lookahead = PlaybackLookahead()
        resetPlayer(keepPlaying: live)
        return request
    }

    func requestHandoff(index: Int, present: @escaping (PlaybackRequest) -> Void) {
        if let request = handoff(index: index) { present(request) }
        else if index == 0, task != nil, !failed {
            pendingPresentation = present
            awaitingHandoff = true
        }
    }

    func beginHold() {
        guard let player, rendered, !paused, !ended, !holding, !speedLocked else { return }
        holding = true; player.rate = 2; Haptics.holdSpeedBegan()
    }
    func endHold() {
        guard holding else { return }
        holding = false
        if !paused, !ended { player?.rate = playbackSpeed }
    }
    func lockSpeed() {
        guard let player, rendered, !paused, !ended, !failed, !speedLocked else { return }
        speedLocked = true; holding = false; player.defaultRate = playbackSpeed; player.rate = playbackSpeed
    }
    func unlockSpeed() {
        guard speedLocked else { return }
        speedLocked = false
        player?.defaultRate = playbackSpeed
        if !paused, !ended { player?.rate = playbackSpeed }
    }
    func toggle() {
        endHold()
        guard let player, !ended else { return }
        if paused { episode?.stream.resume(); player.playImmediately(atRate: playbackSpeed) }
        else { player.pause(); episode?.stream.pause(); lookahead.pause() }
        paused.toggle()
    }

    private func resetPlayer(keepPlaying: Bool = false) {
        layerHost = nil
        pendingPresentation = nil; awaitingHandoff = false
        ticket = UUID(); task?.cancel(); task = nil; frameTask?.cancel(); frameTask = nil
        observations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let periodic { player?.removeTimeObserver(periodic) }; periodic = nil
        if !keepPlaying { player?.pause(); player?.replaceCurrentItem(with: nil) }
        player = nil; episode = nil; dramaID = nil; rendered = false; paused = false
        ended = false; failed = false; holding = false; speedLocked = false
    }
    func stop() { resetPlayer(); lookahead.clear() }
}

extension FeedPreview {
    var duration: Double {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    func seek(to seconds: Double) {
        let length = duration
        guard let player, rendered, !failed, !ended, length > 0, seconds.isFinite else { return }
        let target = min(max(0, seconds), max(0, length - 1))
        endHold()
        let seekID = UUID()
        gestureSeekID = seekID
        episode?.stream.resume()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, let player, self.player === player, self.gestureSeekID == seekID, self.paused else { return }
                self.episode?.stream.pause()
            }
        }
    }
}

struct FeedGestureView: View {
    private let playback: PlaybackGestures?
    private let retry: (() -> Void)?

    init(tap: @escaping () -> Void) {
        playback = nil
        retry = tap
    }

    init(preview: FeedPreview, player: AVPlayer, statusTopInset: CGFloat, statusTrailingInset: CGFloat, restoredSpeed: String) {
        playback = PlaybackGestures(preview: preview, player: player, statusTopInset: statusTopInset,
                                    statusTrailingInset: statusTrailingInset, restoredSpeed: restoredSpeed)
        retry = nil
    }

    var body: some View {
        if let playback {
            playback
        } else if let retry {
            TouchSurface(tap: retry)
                .accessibilityElement().accessibilityLabel("重试预览").accessibilityAddTraits(.isButton)
                .accessibilityAction { retry() }
        }
    }

    private struct PlaybackGestures: View {
        @ObservedObject var preview: FeedPreview
        let player: AVPlayer
        let statusTopInset: CGFloat
        let statusTrailingInset: CGFloat
        let restoredSpeed: String
        @State private var lockZone: SpeedLockZone?
        @State private var seekStart: Double?
        @State private var seekTarget: Double = 0

        private var isCurrent: Bool { preview.player === player }
        private var canSeek: Bool { isCurrent && preview.rendered && !preview.ended && !preview.failed && preview.duration > 0 }
        private var canLock: Bool { isCurrent && preview.rendered && !preview.paused && !preview.ended && !preview.failed && !preview.speedLocked }

        var body: some View {
            TouchSurface(
                tap: { if isCurrent { preview.toggle() } },
                beginHold: { zone in
                    guard canLock else { return false }
                    preview.beginHold()
                    lockZone = zone
                    return preview.holding
                },
                endHold: { if isCurrent { preview.endHold() } },
                lockSpeed: { if canLock && preview.holding { preview.lockSpeed() } },
                changeSeek: updateSeek,
                finishSeek: finishSeek
            )
            .overlay {
                if isCurrent && preview.holding, let lockZone { SpeedLockTarget(zone: lockZone) }
                if canSeek, let seekStart {
                    SeekDragBadge(target: seekTarget, duration: preview.duration, delta: seekTarget - seekStart)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("预览视频")
            .accessibilityValue(preview.speedLocked ? "已锁定 2 倍速" : "")
            .accessibilityHint(preview.paused ? "继续播放预览" : "暂停播放预览")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isCurrent { preview.toggle() } }
            .accessibilityActions {
                if canLock { Button("锁定 2 倍速", action: preview.lockSpeed) }
                if preview.speedLocked { Button("解锁倍速", action: preview.unlockSpeed) }
                if canSeek {
                    Button("快退 10 秒") { preview.seek(to: preview.position - 10) }
                    Button("快进 10 秒") { preview.seek(to: preview.position + 10) }
                }
            }
            .overlay(alignment: .topTrailing) {
                SpeedLockStatus(locked: preview.speedLocked, restoredSpeed: restoredSpeed,
                                identifier: "feed.speedUnlock", unlock: preview.unlockSpeed)
                    .padding(.top, statusTopInset).padding(.trailing, statusTrailingInset)
            }
        }

        private func updateSeek(_ fraction: CGFloat) {
            guard canSeek else { return }
            let start = seekStart ?? preview.position
            seekStart = start
            seekTarget = PlayerSession.dragSeekTarget(start: start, duration: preview.duration, fraction: Double(fraction))
        }

        private func finishSeek(_ fraction: CGFloat?) {
            defer { seekStart = nil }
            guard canSeek, let start = seekStart, let fraction else { return }
            let target = PlayerSession.dragSeekTarget(start: start, duration: preview.duration, fraction: Double(fraction))
            if abs(target - start) > 0.2 { preview.seek(to: target) }
        }
    }

    private struct TouchSurface: UIViewRepresentable {
        let tap: () -> Void
        var beginHold: ((SpeedLockZone) -> Bool)?
        var endHold: () -> Void = {}
        var lockSpeed: () -> Void = {}
        var changeSeek: (CGFloat) -> Void = { _ in }
        var finishSeek: (CGFloat?) -> Void = { _ in }

        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
            tap.delegate = context.coordinator
            if beginHold != nil {
                let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
                hold.minimumPressDuration = 0.35
                hold.allowableMovement = 18
                hold.delegate = context.coordinator
                tap.require(toFail: hold)
                view.addGestureRecognizer(hold)
            }
            view.addGestureRecognizer(tap)
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
        static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.parent.endHold() }

        @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var parent: TouchSurface
            private var holdDrag: HoldDrag?

            init(_ parent: TouchSurface) { self.parent = parent }

            @objc func tapped() { parent.tap() }

            func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
                guard recognizer is UITapGestureRecognizer, let scroll = other.view as? UIScrollView,
                      other === scroll.panGestureRecognizer else { return false }
                return recognizer.view?.isDescendant(of: scroll) == true
            }

            func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
                guard recognizer is UILongPressGestureRecognizer, other is UIPanGestureRecognizer,
                      let scroll = other.view as? UIScrollView else { return false }
                return recognizer.view?.isDescendant(of: scroll) == true
            }

            @objc func hold(_ gesture: UILongPressGestureRecognizer) {
                guard let view = gesture.view else { return }
                let point = gesture.location(in: view)
                switch gesture.state {
                case .began:
                    let zone = SpeedLockZone(start: point, bounds: view.bounds)
                    holdDrag = HoldDrag(start: point, zone: parent.beginHold?(zone) == true ? zone : nil)
                case .changed:
                    switch holdDrag?.update(at: point, in: view.bounds) {
                    case .startedSeeking:
                        parent.endHold()
                        UISelectionFeedbackGenerator().selectionChanged()
                        parent.changeSeek(0)
                    case let .seeking(fraction): parent.changeSeek(fraction)
                    case .lockSpeed: parent.lockSpeed()
                    case nil: break
                    }
                case .ended, .cancelled, .failed:
                    if gesture.state == .ended, case .lockSpeed = holdDrag?.update(at: point, in: view.bounds) {
                        parent.lockSpeed()
                    }
                    let fraction = gesture.state == .ended ? holdDrag?.seekFraction(at: point, width: view.bounds.width) : nil
                    if holdDrag != nil { parent.finishSeek(fraction) }
                    parent.endHold()
                    holdDrag = nil
                default: break
                }
            }
        }
    }
}
