import SwiftUI

@MainActor
struct PlayerMorePanel: View {
    @ObservedObject private var session: PlayerSession
    @ObservedObject private var app: AppModel
    @AppStorage(CommentDanmakuPreference.key) private var commentDanmaku = CommentDanmakuPreference.defaultValue
    @AppStorage(CommentDanmakuPreference.fontSizeKey) private var danmakuFontSize: CommentDanmakuPreference.FontSize = .standard
    @AppStorage(CommentDanmakuPreference.scrollSpeedKey) private var danmakuScrollSpeed: CommentDanmakuPreference.ScrollSpeed = .standard

    private let enterCleanScreen: () -> Void
    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private var colors: ThemeColors { app.appearance }

    init(session: PlayerSession, enterCleanScreen: @escaping () -> Void) {
        self.session = session
        self.app = session.app
        self.enterCleanScreen = enterCleanScreen
    }

    var body: some View {
        PlayerPanel(title: "更多", colors: colors) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    speedOptions
                    qualityOptions

                    VStack(spacing: 0) {
                        sleepTimer
                        Divider()
                        Button(action: enterCleanScreen) {
                            Label("清屏播放", systemImage: "rectangle.inset.filled")
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .background(colors.surface, in: RoundedRectangle(cornerRadius: 14))
                    danmakuOptions
                }
                .foregroundStyle(colors.ink)
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var danmakuOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("弹幕").font(.headline).accessibilityAddTraits(.isHeader)
            Toggle("轮播本集评论弹幕", isOn: $commentDanmaku)
                .frame(minHeight: 44)
            Text("字体大小").foregroundStyle(colors.muted).accessibilityHidden(true)
            Picker("弹幕字体大小", selection: $danmakuFontSize) {
                ForEach(CommentDanmakuPreference.FontSize.allCases) { size in Text(size.title).tag(size) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("player.danmaku.fontSize")
            Text("滚动速度").foregroundStyle(colors.muted).accessibilityHidden(true)
            Picker("弹幕滚动速度", selection: $danmakuScrollSpeed) {
                ForEach(CommentDanmakuPreference.ScrollSpeed.allCases) { speed in Text(speed.title).tag(speed) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("player.danmaku.scrollSpeed")
        }
        .font(.subheadline)
        .tint(colors.accent)
    }

    private var speedOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放倍速").font(.headline).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                speedGrid(columns: 6)
                speedGrid(columns: 3)
                speedGrid(columns: 2)
                speedGrid(columns: 1)
            }
        }
    }

    private func speedGrid(columns: Int) -> some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 8) {
            ForEach(0..<(Self.speeds.count / columns), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let speed = Self.speeds[row * columns + column]
                        PlayerPanelOption(title: String(format: "%g×", speed),
                                          selected: app.speed == speed, colors: colors) {
                            session.setSpeed(speed)
                        }
                    }
                }
            }
        }
    }

    private var qualityOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("清晰度").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                ForEach(VideoQuality.allCases.reversed()) { quality in
                    PlayerPanelOption(title: quality.label, selected: app.quality == quality, colors: colors) {
                        session.setQuality(quality)
                    }
                }
            }
            Text("从当前位置切换，并作为后续剧集的默认清晰度。片源没有所选档位时使用最接近的一档。")
                .font(.footnote)
                .foregroundStyle(colors.muted)
        }
    }

    private var sleepTimer: some View {
        let status = session.sleepTimerLabel

        return Menu {
            Button("播完本集") { session.stopAtEpisodeEnd() }
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) 分钟") { session.setSleepTimer(minutes: minutes) }
            }
            Button("关闭") { session.setSleepTimer(minutes: nil) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                VStack(alignment: .leading, spacing: 3) {
                    Text("定时关闭")
                    Text(status).font(.caption).foregroundStyle(colors.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.muted)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .foregroundStyle(colors.ink)
        }
        .accessibilityLabel("定时关闭")
        .accessibilityValue(status)
    }
}

@MainActor
struct PlayerEpisodePanel: View {
    @ObservedObject private var session: PlayerSession
    @ObservedObject private var app: AppModel
    @ScaledMetric(relativeTo: .subheadline) private var episodeWidth: CGFloat = 49

    private let select: (Int) -> Void
    private let horizontalInset: CGFloat = 20
    private let maximumContentWidth: CGFloat = 680
    private var colors: ThemeColors { app.appearance }
    private var episodes: [Episode] { session.detail.episodes }

    init(session: PlayerSession, select: @escaping (Int) -> Void) {
        self.session = session
        self.app = session.app
        self.select = select
    }

    var body: some View {
        PlayerPanel(title: "选集", colors: colors) {
            VStack(spacing: 0) {
                header
                GeometryReader { geometry in
                    let width = min(geometry.size.width, maximumContentWidth)
                    if width > horizontalInset * 2 {
                        episodeGrid(width: width)
                    }
                }
            }
        }
    }

    private func episodeGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 10
        let gridWidth = width - horizontalInset * 2
        let minimumTileWidth = max(44, min(episodeWidth, 108))
        let columns = max(1, Int((gridWidth + spacing) / (minimumTileWidth + spacing)))
        let rows = (episodes.count + columns - 1) / columns
        let tileWidth = (gridWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        let firstIndex = row * columns
                        let lastIndex = min(firstIndex + columns, episodes.count)
                        HStack(spacing: spacing) {
                            ForEach(Array(episodes[firstIndex..<lastIndex].enumerated()), id: \.element.id) { offset, episode in
                                let index = firstIndex + offset
                                PlayerPanelOption(title: "\(episode.index)", selected: index == session.index,
                                                  colors: colors, showsCheckmark: true) {
                                    select(index)
                                }
                                .frame(width: tileWidth)
                            }
                        }
                        .frame(width: gridWidth, alignment: .leading)
                        .id(row)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                guard episodes.indices.contains(session.index), session.index >= columns else { return }
                proxy.scrollTo(session.index / columns, anchor: .top)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.detail.drama.title)
                .foregroundStyle(colors.ink)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text(episodeSummary)
                .foregroundStyle(colors.muted)
        }
        .font(.playbackHeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, 10)
        .frame(maxWidth: maximumContentWidth)
        .frame(maxWidth: .infinity)
        .background(colors.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var episodeSummary: String {
        let total = "共 \(episodes.count) 集"
        guard episodes.indices.contains(session.index) else { return total }
        return "\(total) · 正在播放第 \(episodes[session.index].index) 集"
    }
}

private struct PlayerPanel<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let colors: ThemeColors
    @ViewBuilder let content: () -> Content

    private var scheme: ColorScheme { colors.dark ? .dark : .light }

    var body: some View {
        NavigationStack {
            content()
                .appBackground(colors)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(scheme, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .tint(colors.accent)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

private struct PlayerPanelOption: View {
    let title: String
    let selected: Bool
    let colors: ThemeColors
    var showsCheckmark = false
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 10)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: showsCheckmark ? 48 : 44)
                .foregroundStyle(selected ? colors.accent : colors.ink)
                .background(selected ? colors.soft : colors.surface, in: shape)
                .overlay {
                    if selected { shape.strokeBorder(colors.accent, lineWidth: 1) }
                }
                .overlay(alignment: .topTrailing) {
                    if selected && showsCheckmark {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(colors.accent)
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
