import Foundation
import AVFoundation
import Combine
import UIKit
import SwiftUI

/// A light tap felt when long-press 2× starts, in the feed and the full player.
@MainActor enum Haptics {
    static func holdSpeedBegan() { let generator = UIImpactFeedbackGenerator(style: .medium); generator.prepare(); generator.impactOccurred() }
}

/// Plays episode 1 of the drama on the current feed page, like a short-video feed. One player at a time: switching
/// pages, leaving the home tab, opening the full player or going to background releases it. The next page's drama is
/// opened and its first seconds downloaded meanwhile, so a swipe starts playing at once. A preview never writes local
/// history or account progress; 立即播放 hands its position to the full player.
@MainActor
final class FeedPreview: ObservableObject {
    @Published private(set) var dramaID: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var rendered = false
    @Published private(set) var paused = false
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var holding = false
    private(set) var detail: DramaDetail?
    private var task: Task<Void, Never>?
    private var ticket = UUID()
    private var stream: ProgressivePlayback?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private struct Prepared { let dramaID: String; let quality: VideoQuality; let detail: DramaDetail; let stream: ProgressivePlayback }
    private var prepared: Prepared?
    private var preparing: (dramaID: String, task: Task<Void, Never>)?

    var position: Double { player.map { max(0, $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : 0) } ?? 0 }

    func play(_ drama: Drama, quality: VideoQuality, retry: Bool = true) {
        guard dramaID != drama.id || failed else { if paused, !ended { toggle() }; return }
        stop(keepPrepared: true)
        dramaID = drama.id
        let ticket = UUID(); self.ticket = ticket
        let ready = takePrepared(drama.id, quality: quality)
        task = Task { [weak self] in
            do {
                let detail: DramaDetail, stream: ProgressivePlayback
                if let ready { detail = ready.detail; stream = ready.stream }
                else {
                    detail = try await DramaDetails.load(drama)
                    guard let first = detail.episodes.first else { throw HGError.message("这部剧暂时没有可播放剧集") }
                    stream = try await EpisodeStream.open(episodeID: first.id, quality: quality)
                }
                guard let self, self.ticket == ticket, !Task.isCancelled else { stream.close(); return }
                self.stream = stream
                self.detail = detail
                self.install(AVPlayerItem(asset: stream.asset), ticket: ticket)
            } catch is CancellationError {
            } catch {
                guard let self, self.ticket == ticket else { return }
                // The playback API intermittently rejects a fresh anonymous identity; try this page once more.
                if retry {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard self.ticket == ticket, !Task.isCancelled else { return }
                    self.dramaID = nil; self.play(drama, quality: quality, retry: false); return
                }
                self.failed = true
            }
        }
    }

    /// Opens the drama on the next page in the background; only one is kept.
    func prepare(_ drama: Drama, quality: VideoQuality) {
        guard drama.id != dramaID, prepared?.dramaID != drama.id || prepared?.quality != quality, preparing?.dramaID != drama.id else { return }
        cancelPrepared()
        let task = Task { [weak self] in
            // The current page goes first.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled,
                  let detail = try? await DramaDetails.load(drama), let first = detail.episodes.first, !Task.isCancelled,
                  let stream = try? await EpisodeStream.open(episodeID: first.id, quality: quality) else { return }
            guard let self, !Task.isCancelled, self.preparing?.dramaID == drama.id else { stream.close(); return }
            self.prepared = Prepared(dramaID: drama.id, quality: quality, detail: detail, stream: stream)
            await EpisodeStream.warm(stream, whole: false)
            if self.preparing?.dramaID == drama.id { self.preparing = nil }
        }
        preparing = (drama.id, task)
    }

    private func takePrepared(_ id: String, quality: VideoQuality) -> Prepared? {
        guard let ready = prepared, ready.dramaID == id, ready.quality == quality else { return nil }
        prepared = nil
        if preparing?.dramaID == id { preparing = nil }
        return ready
    }

    private func cancelPrepared() {
        preparing?.task.cancel(); preparing = nil
        prepared?.stream.close(); prepared = nil
    }

    private func install(_ item: AVPlayerItem, ticket: UUID) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in guard let self, self.ticket == ticket, item.status == .failed else { return }; self.failed = true }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.ticket == ticket else { return }; self.endHold(); self.ended = true; self.paused = true }
        }
        self.player = player
        player.playImmediately(atRate: 1)
    }

    func markRendered() { rendered = true }

    /// Long-press anywhere on the picture: 2× while held, back to normal on release. Paused or ended previews ignore it.
    func beginHold() {
        guard let player, rendered, !paused, !ended, !holding else { return }
        holding = true; player.rate = 2
        Haptics.holdSpeedBegan()
    }

    func endHold() {
        guard holding else { return }
        holding = false
        if !paused, let player { player.rate = 1 }
    }

    func toggle() {
        endHold()
        guard let player, !ended else { return }
        if paused { stream?.resume(); player.play() } else { player.pause(); stream?.pause() }
        paused.toggle()
    }

    /// `keepPrepared` keeps the next page's drama, which is usually the one about to play.
    func stop(keepPrepared: Bool = false) {
        task?.cancel(); task = nil; ticket = UUID()
        observations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        stream?.close(); stream = nil
        if !keepPrepared { cancelPrepared() }
        holding = false; dramaID = nil; detail = nil; rendered = false; paused = false; ended = false; failed = false
    }
}

/// Tap and long-press for a feed page. No pan recognizer: vertical paging stays with the scroll view, and a
/// finger that moves before the hold fires lets the scroll view take over.
struct FeedGestureView: UIViewRepresentable {
    let tap: () -> Void
    let holdBegan: () -> Void
    let holdEnded: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35; hold.allowableMovement = 18
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)); tap.require(toFail: hold)
        view.addGestureRecognizer(hold); view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.parent.holdEnded() }
    @MainActor final class Coordinator: NSObject {
        var parent: FeedGestureView
        init(_ parent: FeedGestureView) { self.parent = parent }
        @objc func tapped() { parent.tap() }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { parent.holdBegan() }
            if [.ended, .cancelled, .failed].contains(gesture.state) { parent.holdEnded() }
        }
    }
}
