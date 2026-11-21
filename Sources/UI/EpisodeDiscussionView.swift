import AVFoundation
import SwiftUI

struct DiscussionEpisode: Hashable {
    let seriesID: String
    let episodeID: String
    let number: Int
}

struct DiscussionControls: View {
    @AppStorage("playback.commentDanmaku") private var enabled = false
    @Environment(\.episodeCommentPreview) private var preview
    var vertical = false
    let showComments: () -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 2))
        let available = preview?.hasDisplayableComments == true
        let count = preview?.displayCount
        layout {
            Button { enabled.toggle() } label: {
                AppControlIcon(name: available && enabled ? "captions.bubble.fill" : "captions.bubble")
                    .opacity(available ? 1 : 0.45)
            }
            .disabled(!available)
            .accessibilityLabel("评论弹幕")
            .accessibilityValue(available ? (enabled ? "开启" : "关闭") : "暂不可用，请查看本集评论")
            .accessibilityIdentifier("discussion.toggle")
            Button(action: showComments) {
                AppControlIcon(name: "text.bubble")
                    .offset(y: count == nil ? 0 : -6)
                    .overlay(alignment: .bottom) {
                        if let count {
                            Text(count.formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("本集评论").accessibilityValue(count.map { "\($0) 条" } ?? "暂未取得数量")
            .accessibilityIdentifier("discussion.comments")
        }.buttonStyle(.plain)
    }
}

private enum EpisodeCommentPreviewKey: EnvironmentKey {
    static let defaultValue: EpisodeCommentPreview? = nil
}

extension EnvironmentValues {
    var episodeCommentPreview: EpisodeCommentPreview? {
        get { self[EpisodeCommentPreviewKey.self] }
        set { self[EpisodeCommentPreviewKey.self] = newValue }
    }
}

private struct EpisodeDiscussionPresentation: ViewModifier {
    let episode: DiscussionEpisode?
    let player: AVPlayer?
    let playing: Bool
    let foreground: Bool
    let hideDanmaku: Bool
    @Binding var presented: Bool
    @AppStorage("playback.commentDanmaku") private var enabled = false
    @State private var result: (episode: DiscussionEpisode, outcome: Outcome)?
    @State private var retry = 0

    private enum Outcome {
        case preview(EpisodeCommentPreview)
        case unavailable
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
        .overlay(alignment: .top) {
            if enabled, foreground, !hideDanmaku, !presented, let preview, preview.hasDisplayableComments, let player {
                CommentDanmaku(comments: preview.items, player: player, playing: playing)
                    .padding(.top, 68)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: request) {
            guard let target = request.episode else { return }
            switch outcome {
            case .preview, .unavailable: return
            case .failed, nil: break
            }
            result = nil
            do {
                let preview = try await EpisodeDiscussionAPI.preview(seriesID: target.seriesID, episodeID: target.episodeID)
                try Task.checkCancellation()
                result = (target, .preview(preview))
            } catch {
                guard !Task.isCancelled else { return }
                if error as? EpisodeDiscussionAPI.ReadError == .unavailable {
                    result = (target, .unavailable)
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
                        case .unavailable:
                            ContentUnavailableView("官网暂未开放本集评论", systemImage: "text.bubble")
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
                ContentUnavailableView("官网没有可读评论预览", systemImage: "text.bubble",
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
    func episodeDiscussion(_ episode: DiscussionEpisode?, player: AVPlayer?, playing: Bool, foreground: Bool,
                           hideDanmaku: Bool = false, presented: Binding<Bool>) -> some View {
        modifier(EpisodeDiscussionPresentation(episode: episode, player: player, playing: playing,
                                               foreground: foreground, hideDanmaku: hideDanmaku, presented: presented))
    }
}

private struct CommentDanmaku: View {
    let comments: [EpisodeComment]
    let player: AVPlayer
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = comments.map { String($0.singleLineText.prefix(70)) }
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1 / 24, paused: !playing)) { _ in
            let seconds = player.currentTime().seconds
            Canvas { context, size in
                guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max), !lines.isEmpty else { return }
                let lanes = reduceMotion ? 1 : min(3, lines.count)
                let spacing = reduceMotion ? 6.0 : 8.4 / Double(lanes)
                let latest = Int(seconds / spacing)
                for index in max(0, latest - lanes + 1)...latest {
                    let text = lines[index % lines.count]
                    let label = context.resolve(Text(verbatim: text).font(.subheadline.weight(.semibold)).foregroundStyle(.white))
                    let width = label.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 28)).width
                    let phase = (seconds - Double(index) * spacing) / (spacing * Double(lanes))
                    let entryX = size.width - min(width, 44)
                    let x = reduceMotion ? 12 : entryX - phase * (entryX + width + 12)
                    let y = CGFloat(index % lanes) * 26
                    var shadow = context
                    shadow.addFilter(.shadow(color: .black, radius: 1.5, y: 1))
                    shadow.draw(label, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            }.frame(height: reduceMotion ? 28 : 80).clipped()
        }
    }
}
