import AVFoundation
import SwiftUI

struct DiscussionEpisode: Hashable {
    let seriesID: String
    let episodeID: String
    let number: Int
}

enum CommentDanmakuPreference {
    static let key = "playback.commentDanmaku"
    static let defaultValue = true
    static let fontSizeKey = "playback.commentDanmaku.fontSize"
    static let scrollSpeedKey = "playback.commentDanmaku.scrollSpeed"

    enum FontSize: String, CaseIterable, Identifiable {
        case small, standard, large
        var id: Self { self }
        var title: String { switch self { case .small: "小"; case .standard: "中"; case .large: "大" } }
        var points: CGFloat { switch self { case .small: 12; case .standard: 15; case .large: 19 } }
    }

    enum ScrollSpeed: String, CaseIterable, Identifiable {
        case slow, standard, fast
        var id: Self { self }
        var title: String { switch self { case .slow: "慢"; case .standard: "标准"; case .fast: "快" } }
        var multiplier: Double { switch self { case .slow: 0.75; case .standard: 1; case .fast: 1.35 } }
    }
}

struct DiscussionControls: View {
    @AppStorage(CommentDanmakuPreference.key) private var enabled = CommentDanmakuPreference.defaultValue
    @Environment(\.episodeCommentPreview) private var preview
    var vertical = false
    let showComments: () -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 2))
        let available = preview?.hasDisplayableComments == true
        let danmakuCount = preview?.playableDanmakuCount
        let commentCount = preview?.displayCount
        let commentCountValue = commentCount.map { count in
            preview?.totalCount == nil ? "公开预览 \(count) 条" : "\(count) 条"
        } ?? "暂未取得数量"
        layout {
            Button { enabled.toggle() } label: {
                InteractionButtonIcon(glyph: .danmaku(enabled: available && enabled), count: danmakuCount)
                    .opacity(available ? 1 : 0.45)
            }
            .disabled(!available)
            .accessibilityLabel("评论弹幕")
            .accessibilityValue(available ? (enabled ? "开启" : "关闭") : "暂无可轮播内容")
            .accessibilityHint(danmakuCount.map { "轮播本集 \($0) 条公开评论" } ?? "查看本集评论了解内容状态")
            .accessibilityIdentifier("discussion.toggle")
            Button(action: showComments) {
                InteractionButtonIcon(glyph: .symbol("text.bubble"), count: commentCount)
            }
            .accessibilityLabel("本集评论").accessibilityValue(commentCountValue)
            .accessibilityHint("打开本集评论")
            .accessibilityIdentifier("discussion.comments")
        }.buttonStyle(.plain)
    }
}

private enum EpisodeCommentPreviewKey: EnvironmentKey {
    static let defaultValue: EpisodeCommentPreview? = nil
}

private enum DiscussionSeriesFavoriteCountKey: EnvironmentKey {
    static let defaultValue: (seriesID: String, count: Int)? = nil
}

extension EnvironmentValues {
    var episodeCommentPreview: EpisodeCommentPreview? {
        get { self[EpisodeCommentPreviewKey.self] }
        set { self[EpisodeCommentPreviewKey.self] = newValue }
    }

    var discussionSeriesFavoriteCount: (seriesID: String, count: Int)? {
        get { self[DiscussionSeriesFavoriteCountKey.self] }
        set { self[DiscussionSeriesFavoriteCountKey.self] = newValue }
    }
}

private struct EpisodeDiscussionPresentation: ViewModifier {
    let episode: DiscussionEpisode?
    let player: AVPlayer?
    let foreground: Bool
    let hideDanmaku: Bool
    @Binding var presented: Bool
    @AppStorage(CommentDanmakuPreference.key) private var enabled = CommentDanmakuPreference.defaultValue
    @State private var result: (episode: DiscussionEpisode, outcome: Outcome)?
    @State private var seriesFavoriteCount: (seriesID: String, count: Int)?
    @State private var retry = 0

    private enum Outcome {
        case preview(EpisodeCommentPreview)
        case restricted
        case failed(String)
    }

    private struct Request: Equatable {
        let episode: DiscussionEpisode?
        let retry: Int
    }

    private var request: Request {
        Request(episode: foreground ? episode : nil, retry: retry)
    }

    private var outcome: Outcome? {
        guard let result, result.episode == episode else { return nil }
        return result.outcome
    }

    private var preview: EpisodeCommentPreview? {
        guard case .preview(let preview) = outcome else { return nil }
        return preview
    }

    func body(content: Content) -> some View {
        content.environment(\.episodeCommentPreview, preview)
        .environment(\.discussionSeriesFavoriteCount, seriesFavoriteCount?.seriesID == episode?.seriesID ? seriesFavoriteCount : nil)
        .overlay(alignment: .top) {
            if enabled, foreground, !hideDanmaku, !presented, let preview, preview.hasDisplayableComments, let player {
                CommentDanmaku(comments: preview.items, player: player)
                    .id(episode)
                    .padding(.top, 68)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: request) {
            guard let target = request.episode else { return }
            switch outcome {
            case .preview, .restricted: return
            case .failed, nil: break
            }
            result = nil
            do {
                let preview = try await EpisodeDiscussionAPI.preview(seriesID: target.seriesID, episodeID: target.episodeID)
                try Task.checkCancellation()
                if let count = preview.seriesFavoriteCount { seriesFavoriteCount = (target.seriesID, count) }
                result = (target, .preview(preview))
            } catch {
                guard !Task.isCancelled else { return }
                if error as? EpisodeDiscussionAPI.ReadError == .restrictedEpisode {
                    result = (target, .restricted)
                } else {
                    let message = (error as? EpisodeDiscussionAPI.ReadError)?.errorDescription ?? "请检查网络后重试。"
                    result = (target, .failed(message))
                }
            }
        }
        .onChange(of: presented) { _, open in
            if open, case .failed = outcome { retry += 1 }
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                Group {
                    if episode == nil {
                        ContentUnavailableView("当前分集信息暂不可用", systemImage: "text.bubble")
                    } else {
                        switch outcome {
                        case nil:
                            ProgressView("正在加载本集评论")
                        case .failed(let message):
                            ContentUnavailableView {
                                Label("评论暂时无法加载", systemImage: "wifi.exclamationmark")
                            } description: {
                                Text(message)
                            } actions: { Button("重试") { retry += 1 } }
                        case .restricted:
                            ContentUnavailableView("本集评论暂不可读", systemImage: "text.bubble",
                                                   description: Text(EpisodeDiscussionAPI.ReadError.restrictedEpisode.localizedDescription))
                        case .preview(let preview):
                            commentList(preview)
                        }
                    }
                }
                .navigationTitle(episode.map { "第 \($0.number) 集评论" } ?? "本集评论")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presented = false } } }
                .safeAreaInset(edge: .bottom) {
                    if preview?.hasDisplayableComments == true {
                        Toggle("轮播本集评论弹幕", isOn: $enabled)
                            .font(.subheadline).padding(.horizontal).padding(.vertical, 8).background(.bar)
                    }
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func commentList(_ preview: EpisodeCommentPreview) -> some View {
        if !preview.hasDisplayableComments {
            if preview.totalCount == 0 {
                ContentUnavailableView("本集暂无公开评论", systemImage: "text.bubble")
            } else {
                ContentUnavailableView("官网未返回可读评论", systemImage: "text.bubble",
                                       description: preview.totalCount.map { Text("官网显示共 \($0) 条评论。") })
            }
        } else {
            List {
                Section {
                    ForEach(preview.items) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundStyle(.secondary) }
                            Text(entry.text).font(.body).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                } header: {
                    if let total = preview.totalCount, total > preview.previewCount {
                        Text("共 \(total) 条评论 · 官网公开预览 \(preview.previewCount) 条")
                    } else {
                        Text("官方播放页公开评论 · \(preview.previewCount) 条")
                    }
                }
            }.listStyle(.plain)
        }
    }
}

extension View {
    func episodeDiscussion(_ episode: DiscussionEpisode?, player: AVPlayer?, foreground: Bool,
                           hideDanmaku: Bool = false, presented: Binding<Bool>) -> some View {
        modifier(EpisodeDiscussionPresentation(episode: episode, player: player,
                                               foreground: foreground, hideDanmaku: hideDanmaku, presented: presented))
    }
}

private struct CommentDanmaku: View {
    let comments: [EpisodeComment]
    let player: AVPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CommentDanmakuPreference.fontSizeKey) private var fontSize: CommentDanmakuPreference.FontSize = .standard
    @AppStorage(CommentDanmakuPreference.scrollSpeedKey) private var scrollSpeed: CommentDanmakuPreference.ScrollSpeed = .standard
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: TimeInterval?

    var body: some View {
        let labels = ForEach(comments) { comment in
            Text(verbatim: String(comment.singleLineText.prefix(70)))
                .font(.system(size: fontSize.points, weight: .semibold)).foregroundStyle(.white)
                .fixedSize().shadow(color: .black, radius: 1.5, y: 1)
                .padding(2).tag(comment.id)
        }
        let lanes = reduceMotion ? 1 : min(3, comments.count)
        let laneHeight = fontSize.points + 11
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : nil, paused: startedAt == nil)) { _ in
            let seconds = elapsed + (startedAt.map { (CACurrentMediaTime() - $0) * scrollSpeed.multiplier } ?? 0)
            Canvas { context, size in
                guard lanes > 0 else { return }
                let spacing = reduceMotion ? 6.0 : 10.0 / Double(lanes)
                let latest = Int(seconds / spacing)
                for index in max(0, latest - lanes + 1)...latest {
                    let id = comments[index % comments.count].id
                    guard let label = context.resolveSymbol(id: id) else { continue }
                    let width = label.size.width
                    let phase = (seconds - Double(index) * spacing) / (spacing * Double(lanes))
                    let entryX = size.width - min(width, 44)
                    let x = reduceMotion ? 12 : entryX - phase * (entryX + width + 12)
                    let y = CGFloat(index % lanes) * laneHeight
                    context.draw(label, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            } symbols: { labels }
            .frame(height: CGFloat(lanes) * laneHeight + 2).clipped()
        }
        .onChange(of: player, initial: true) { _, _ in alignToVideo() }
        .onChange(of: scrollSpeed) { previousSpeed, _ in
            guard let start = startedAt else { return }
            let now = CACurrentMediaTime()
            elapsed += (now - start) * previousSpeed.multiplier
            startedAt = now
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemTimeJumped)) { event in
            if let item = event.object as? AVPlayerItem, item === player.currentItem { alignToVideo() }
        }
        .onReceive(player.publisher(for: \.timeControlStatus).removeDuplicates().receive(on: RunLoop.main)) { _ in
            let now = CACurrentMediaTime()
            if player.timeControlStatus == .playing {
                if startedAt == nil { startedAt = now }
            } else if let start = startedAt {
                elapsed += (now - start) * scrollSpeed.multiplier
                startedAt = nil
            }
        }
    }

    private func alignToVideo() {
        let seconds = player.currentTime().seconds
        elapsed = seconds.isFinite && seconds >= 0 && seconds < Double(Int32.max) ? seconds * scrollSpeed.multiplier : 0
        startedAt = player.timeControlStatus == .playing ? CACurrentMediaTime() : nil
    }
}
