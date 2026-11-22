import AVFoundation
import SwiftUI
import UIKit

struct TimedEpisodeDanmaku: View {
    let items: [EpisodeDanmaku]
    let player: AVPlayer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CommentDanmakuPreference.fontSizeKey) private var fontSize: CommentDanmakuPreference.FontSize = .standard
    @AppStorage(CommentDanmakuPreference.scrollSpeedKey) private var scrollSpeed: CommentDanmakuPreference.ScrollSpeed = .standard
    @State private var timeline = TimedDanmakuTimeline()
    @State private var playing = false
    @State private var discontinuity = 0

    var body: some View {
        let font = UIFont.systemFont(ofSize: fontSize.points, weight: .semibold)
        let laneHeight = fontSize.points + 11
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : nil, paused: !playing)) { _ in
                let labels = timeline.frame(
                    items: items, mediaTime: player.currentTime().seconds,
                    hostTime: CACurrentMediaTime(), rate: Double(player.rate),
                    playing: player.currentItem != nil && player.timeControlStatus == .playing,
                    width: geometry.size.width, fontSize: fontSize.points, reduceMotion: reduceMotion,
                    speed: scrollSpeed.multiplier
                ) { text in
                    ceil((text as NSString).size(withAttributes: [.font: font]).width)
                }
                Canvas { context, _ in
                    context.addFilter(.shadow(color: .black, radius: 1.5, y: 1))
                    for label in labels {
                        let text = Text(verbatim: label.text)
                            .font(.system(size: font.pointSize, weight: .semibold))
                            .foregroundStyle(.white)
                        context.draw(text, at: CGPoint(x: label.x, y: CGFloat(label.lane) * laneHeight + 2),
                                     anchor: .topLeading)
                    }
                }
            }
            .id(discontinuity)
        }
        .frame(height: laneHeight * CGFloat(reduceMotion ? 1 : TimedDanmakuTimeline.laneCount) + 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { realign() }
        .onChange(of: player) { _, _ in realign() }
        .onReceive(player.publisher(for: \.currentItem, options: [.new]).receive(on: DispatchQueue.main)) { _ in
            realign()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemTimeJumped).receive(on: DispatchQueue.main)) { event in
            guard let item = event.object as? AVPlayerItem, item === player.currentItem else { return }
            realign()
        }
        .onReceive(player.publisher(for: \.timeControlStatus).removeDuplicates().receive(on: DispatchQueue.main)) { status in
            if status != .playing { timeline.freeze() }
            playing = status == .playing
        }
    }

    private func realign() {
        timeline.reset(at: player.currentTime().seconds)
        playing = player.timeControlStatus == .playing
        discontinuity &+= 1
    }
}

private final class TimedDanmakuTimeline {
    struct Label {
        let text: String
        let x: CGFloat
        let lane: Int
    }

    private struct Entry {
        let text: String
        let lane: Int
        let width: CGFloat
        let startDistance: CGFloat
    }

    static let laneCount = 3
    private static let pointsPerSecond: CGFloat = 60
    private static let laneGap: CGFloat = 12
    private static let staticDistance = 6 * pointsPerSecond

    private var entries: [Entry] = []
    private var laneAvailableAt = Array(repeating: CGFloat.zero, count: laneCount)
    private var distance: CGFloat = 0
    private var nextMediaTime: Double?
    private var lastMediaTime: Double?
    private var lastHostTime: Double?
    private var lastFontSize: CGFloat?
    private var lastReduceMotion: Bool?

    func reset(at mediaTime: Double) {
        entries.removeAll(keepingCapacity: true)
        distance = 0
        laneAvailableAt = Array(repeating: .zero, count: Self.laneCount)
        nextMediaTime = mediaTime.isFinite && mediaTime >= 0 ? mediaTime : nil
        lastMediaTime = nil
        freeze()
    }

    func freeze() {
        lastHostTime = nil
    }

    func frame(items: [EpisodeDanmaku], mediaTime: Double, hostTime: Double, rate: Double, playing: Bool,
               width: CGFloat, fontSize: CGFloat, reduceMotion: Bool, speed: Double,
               measure: (String) -> CGFloat) -> [Label] {
        guard mediaTime.isFinite, mediaTime >= 0 else {
            reset(at: mediaTime)
            return []
        }
        if lastFontSize != fontSize || lastReduceMotion != reduceMotion {
            reset(at: nextMediaTime ?? mediaTime)
            lastFontSize = fontSize
            lastReduceMotion = reduceMotion
        }

        let wallDelta = lastHostTime.map { max(0, hostTime - $0) } ?? 0
        let mediaDelta = mediaTime - (lastMediaTime ?? mediaTime)
        if mediaDelta < 0 || (playing && lastHostTime != nil && mediaDelta > wallDelta * rate + 0.25) {
            reset(at: mediaTime)
        } else if playing && mediaDelta > 0 {
            distance += CGFloat(wallDelta * speed) * Self.pointsPerSecond
        }
        lastMediaTime = mediaTime
        lastHostTime = playing ? hostTime : nil

        entries.removeAll { entry in
            let lifetime = reduceMotion ? Self.staticDistance : width + entry.width
            return distance - entry.startDistance >= lifetime
        }
        if playing, rate > 0, width > 0, mediaTime >= (nextMediaTime ?? mediaTime) {
            admit(items, from: nextMediaTime ?? mediaTime, through: mediaTime, reduceMotion: reduceMotion, measure: measure)
            nextMediaTime = mediaTime.nextUp
        }

        return entries.map { entry in
            let x = reduceMotion ? Self.laneGap : width - (distance - entry.startDistance)
            return Label(text: entry.text, x: x, lane: entry.lane)
        }
    }

    private func admit(_ items: [EpisodeDanmaku], from start: Double, through end: Double,
                       reduceMotion: Bool, measure: (String) -> CGFloat) {
        let lanes = reduceMotion ? 1 : Self.laneCount
        guard laneAvailableAt.prefix(lanes).contains(where: { $0 <= distance }) else { return }

        var lower = items.startIndex
        var upper = items.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Double(items[middle].offsetMs) / 1_000 < start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        for item in items[lower...].prefix(24) {
            guard Double(item.offsetMs) / 1_000 <= end,
                  let lane = laneAvailableAt.prefix(lanes).firstIndex(where: { $0 <= distance }) else { break }
            let text = String(item.text.prefix(70).split(whereSeparator: \.isWhitespace).joined(separator: " "))
            guard !text.isEmpty else { continue }
            let width = reduceMotion ? 0 : measure(text)
            entries.append(Entry(text: text, lane: lane, width: width, startDistance: distance))
            laneAvailableAt[lane] = distance + (reduceMotion ? Self.staticDistance : width + Self.laneGap)
        }
    }
}
