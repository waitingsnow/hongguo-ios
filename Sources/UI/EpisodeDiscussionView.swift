import AVFoundation
import SwiftUI

struct DiscussionEpisode: Hashable {
    let seriesID: String
    let episodeID: String
    let number: Int
}

struct DiscussionControls: View {
    @AppStorage("playback.commentDanmaku") private var enabled = false
    let showComments: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { enabled.toggle() } label: {
                Text("弹").font(.system(size: 14, weight: .semibold))
                    .padding(3)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.2) }
                    .foregroundStyle(enabled ? Color(hex: 0xFFAD86) : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("评论弹幕").accessibilityValue(enabled ? "开启" : "关闭")
            .accessibilityIdentifier("discussion.toggle")
            Button(action: showComments) {
                Image(systemName: "text.bubble").font(.system(size: 18)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("本集评论").accessibilityIdentifier("discussion.comments")
        }.buttonStyle(.plain)
    }
}

private struct EpisodeDiscussionPresentation: ViewModifier {
    let episode: DiscussionEpisode?
    let player: AVPlayer?
    let playing: Bool
    let foreground: Bool
    @Binding var presented: Bool
    @AppStorage("playback.commentDanmaku") private var enabled = false
    @State private var loadedEpisode: DiscussionEpisode?
    @State private var comments: [EpisodeComment] = []
    @State private var failure: String?
    @State private var retry = 0

    private struct Request: Equatable {
        let episode: DiscussionEpisode?
        let retry: Int
    }
    private var request: Request {
        Request(episode: foreground && (enabled || presented) ? episode : nil, retry: retry)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if enabled, foreground, !presented, loadedEpisode == episode, !comments.isEmpty, let player {
                CommentDanmaku(comments: comments, player: player, playing: playing)
                    .padding(.top, 68)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: request) {
            guard let target = request.episode else { return }
            guard target != loadedEpisode || failure != nil else { return }
            loadedEpisode = nil; comments = []; failure = nil
            do {
                let entries = try await EpisodeDiscussionAPI.comments(seriesID: target.seriesID, episodeID: target.episodeID)
                try Task.checkCancellation()
                comments = entries; loadedEpisode = target
            } catch {
                guard !Task.isCancelled else { return }
                loadedEpisode = target
                failure = (error as? EpisodeDiscussionAPI.ReadError)?.errorDescription ?? "请检查网络后重试。"
            }
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                Group {
                    if episode == nil {
                        ContentUnavailableView("当前分集信息暂不可用", systemImage: "text.bubble")
                    } else if loadedEpisode != episode {
                        ProgressView("正在加载本集评论")
                    } else if let failure {
                        ContentUnavailableView {
                            Label("评论暂时无法加载", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(failure)
                        } actions: { Button("重试") { retry += 1 } }
                    } else if comments.isEmpty {
                        ContentUnavailableView("本集暂无公开评论", systemImage: "text.bubble")
                    } else {
                        List {
                            Section {
                                ForEach(comments) { entry in
                                    VStack(alignment: .leading, spacing: 5) {
                                        if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundStyle(.secondary) }
                                        Text(entry.text).font(.body).textSelection(.enabled)
                                    }.padding(.vertical, 4)
                                }
                            } header: { Text("官方播放页公开评论 · \(comments.count) 条") }
                        }.listStyle(.plain)
                    }
                }
                .navigationTitle(episode.map { "第 \($0.number) 集评论" } ?? "本集评论")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presented = false } } }
                .safeAreaInset(edge: .bottom) {
                    Toggle("轮播本集评论弹幕", isOn: $enabled)
                        .font(.subheadline).padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func episodeDiscussion(_ episode: DiscussionEpisode?, player: AVPlayer?, playing: Bool, foreground: Bool,
                           presented: Binding<Bool>) -> some View {
        modifier(EpisodeDiscussionPresentation(episode: episode, player: player, playing: playing,
                                               foreground: foreground, presented: presented))
    }
}

private struct CommentDanmaku: View {
    let comments: [EpisodeComment]
    let player: AVPlayer
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : 1 / 24, paused: !playing)) { _ in
            Canvas { context, size in
                let seconds = player.currentTime().seconds
                guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max), !comments.isEmpty else { return }
                let lanes = reduceMotion ? 1 : min(3, comments.count)
                let spacing = reduceMotion ? 6.0 : 8.4 / Double(lanes)
                let latest = Int(seconds / spacing)
                for index in max(0, latest - lanes + 1)...latest {
                    let text = String(comments[index % comments.count].text.prefix(70))
                    let label = context.resolve(Text(verbatim: text).font(.subheadline.weight(.semibold)).foregroundStyle(.white))
                    let width = label.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 28)).width
                    let phase = (seconds - Double(index) * spacing) / (spacing * Double(lanes))
                    let x = reduceMotion ? 12 : size.width - phase * (size.width + width + 12)
                    let y = CGFloat(index % lanes) * 26
                    var shadow = context
                    shadow.addFilter(.shadow(color: .black, radius: 1.5, y: 1))
                    shadow.draw(label, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            }.frame(height: reduceMotion ? 28 : 80).clipped()
        }
    }
}
