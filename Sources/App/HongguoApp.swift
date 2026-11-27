import SwiftUI
import UIKit

@main
struct HongguoApp: App {
    @UIApplicationDelegateAdaptor(HongguoAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var library = LibraryStore.shared
    /// Covers go through Nuke's memory and disk caches (`ImageLoading`).
    init() { ImageLoading.configure() }
    var body: some Scene { WindowGroup { RootView().environmentObject(model).environmentObject(library) } }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasChosenTheme") private var hasChosenTheme = false
    @State private var welcomeVisible = false
    @State private var pendingTheme = AppTheme.warm

    var body: some View {
        tabs
        .overlay { openingOverlay }
        .alert("暂时无法播放", isPresented: openErrorVisible) { Button("好") { model.openError = nil } } message: { Text(model.openError ?? "") }
        .sheet(isPresented: $welcomeVisible, onDismiss: { hasChosenTheme = true }) { themeWelcome }
        .onChange(of: model.windowStyle) { _, _ in model.applyWindowStyle() }
        .onAppear { model.startAppearanceTracking(); if !hasChosenTheme { pendingTheme = model.theme; welcomeVisible = true } }
        .onChange(of: systemScheme) { _, _ in model.refreshSystemAppearance() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.flush() }
            else { model.startAppearanceTracking(); AccountService.shared.resumePendingUploads() }
        }
        .task { if AccountService.shared.hasCredentials { await AccountService.shared.verify() } }
    }

    // Kept out of `body`: the release runner's compiler times out type-checking long inline modifier chains.
    private var tabs: some View {
        let immersive = model.appearance == .immersive
        return TabView(selection: $model.tab) {
            stack { HomeView() }.tabItem { Label("首页", systemImage: "house") }.tag(0)
            stack { DiscoverView() }.tabItem { Label(immersive ? "剧场" : "发现", systemImage: "safari") }.tag(1)
            stack { LibraryView() }.tabItem { Label(immersive ? "追剧" : "片单", systemImage: "rectangle.stack") }.tag(2)
            stack { MyView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(model.appearance.accent)
        .toolbarBackground(model.appearance.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }
    @ViewBuilder private var openingOverlay: some View {
        if scenePhase == .active, let dramaID = model.openingDramaID {
            DelayedPlaybackLoading {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("正在获取选集…")
                        .padding(23).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19))
                }
            }.id(dramaID)
        }
    }
    private var openErrorVisible: Binding<Bool> { Binding(get: { model.openError != nil }, set: { if !$0 { model.openError = nil } }) }

    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationDestination(for: Drama.self) { DetailView(drama: $0) }
                .background(NavigationTabBar(hidden: false))
        }
    }

    private var themeWelcome: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) { Text("选择喜欢的界面风格").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("三种风格，同样精彩。之后可在「我的 › 设置 › 主题样式」随时切换。").font(.subheadline).foregroundStyle(model.appearance.muted); ForEach(AppTheme.allCases) { theme in Button { pendingTheme = theme } label: { ThemePreview(theme: theme, selected: pendingTheme == theme) }.buttonStyle(.plain) }; Button { model.theme = pendingTheme; hasChosenTheme = true; welcomeVisible = false } label: { Text("开始发现好故事").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(model.appearance.accent); Button("暂不选择，保持当前风格") { hasChosenTheme = true; welcomeVisible = false }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(model.appearance.muted) }.padding(22) }.background(model.appearance.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("稍后") { hasChosenTheme = true; welcomeVisible = false } } }
        }.presentationDragIndicator(.visible)
    }
}

enum HorizontalSwipeDirection {
    case left, right

    init?(movement: CGPoint, minimumDistance: CGFloat = 0) {
        guard abs(movement.x) >= minimumDistance, abs(movement.x) > abs(movement.y) * 1.35 else { return nil }
        self = movement.x < 0 ? .left : .right
    }

    func completes(_ movement: CGPoint) -> Bool {
        Self(movement: movement, minimumDistance: 56) == self
    }
}

extension View {
    func playbackDestination(_ request: Binding<PlaybackRequest?>) -> some View {
        navigationDestination(item: request) { PlaybackDestination(request: $0) }
    }
}

private struct PlaybackDestination: View {
    @EnvironmentObject private var model: AppModel
    @State private var request: PlaybackRequest

    init(request: PlaybackRequest) { _request = State(initialValue: request) }

    var body: some View {
        PlayerScreen(request: request, model: model) { request = $0 }
            .id(request.id)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .navigationBar)
            .background(NavigationTabBar(hidden: true))
    }
}

struct NavigationTabBar: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> Controller { Controller(hidden: hidden) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        let hidden: Bool

        init(hidden: Bool) {
            self.hidden = hidden
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            updateTabBar()
        }

        private func updateTabBar() {
            guard let navigationController, let tabs = tabBarController else { return }
            var page = parent
            while let ancestor = page, ancestor.parent !== navigationController { page = ancestor.parent }
            guard let page else { return }

            let bar = tabs.tabBar
            let wasHidden: Bool
            if #available(iOS 18.0, *) { wasHidden = tabs.isTabBarHidden }
            else { wasHidden = bar.isHidden }
            guard wasHidden != hidden else { return }

            guard let transition = navigationController.transitionCoordinator,
                  let source = transition.viewController(forKey: .from),
                  let destination = transition.viewController(forKey: .to), source !== destination,
                  destination === page, navigationController.viewControllers.contains(destination) else {
                if navigationController.transitionCoordinator == nil && navigationController.topViewController === page {
                    Self.setHidden(hidden, in: tabs)
                }
                return
            }

            guard let container = tabs.viewIfLoaded, bar.bounds.width > 0, bar.bounds.height > 0 else {
                Self.setHidden(hidden, in: tabs)
                return
            }
            if wasHidden {
                Self.setHidden(false, in: tabs)
                let offset = bar.bounds.height + container.safeAreaInsets.bottom
                bar.transform = CGAffineTransform(translationX: 0, y: offset)
                let accepted = transition.animateAlongsideTransition(in: bar, animation: { _ in
                    bar.transform = .identity
                }, completion: { context in
                    Self.setHidden(context.isCancelled, in: tabs)
                    bar.transform = .identity
                })
                if !accepted { bar.transform = .identity }
                return
            }
            let frame = bar.convert(bar.bounds, to: container)
            let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
                container.drawHierarchy(in: container.bounds.offsetBy(dx: -frame.minX, dy: -frame.minY), afterScreenUpdates: false)
            }
            let snapshot = UIImageView(image: image)
            let offscreen = frame.offsetBy(dx: 0, dy: container.bounds.maxY - frame.minY)
            snapshot.frame = frame
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            container.addSubview(snapshot)
            Self.setHidden(true, in: tabs)
            let accepted = transition.animateAlongsideTransition(in: container, animation: { _ in
                snapshot.frame = offscreen
            }, completion: { context in
                if context.isCancelled { Self.setHidden(false, in: tabs) }
                snapshot.removeFromSuperview()
            })
            if !accepted { snapshot.removeFromSuperview() }
        }

        private static func setHidden(_ hidden: Bool, in tabs: UITabBarController) {
            if #available(iOS 18.0, *) { tabs.setTabBarHidden(hidden, animated: false) }
            else { tabs.tabBar.isHidden = hidden }
        }
    }
}

struct InteractiveBackSwipe: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled
        controller.pop = { dismiss() }
        controller.attach()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detach()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        #if DEBUG
        private static let testNativePopDeclines = ProcessInfo.processInfo.arguments.contains("--qa-native-pop-declines")
        #endif

        var enabled = false
        var pop: (() -> Void)?
        private weak var owner: UIViewController?
        private var gestures: [InstalledGesture] = []
        private lazy var backPan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBackPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()

        private final class InstalledGesture {
            weak var recognizer: UIGestureRecognizer?
            weak var delegate: UIGestureRecognizerDelegate?
            let wasEnabled: Bool

            init(_ recognizer: UIGestureRecognizer) {
                self.recognizer = recognizer
                delegate = recognizer.delegate
                wasEnabled = recognizer.isEnabled
            }
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            detach()
        }

        func attach() {
            guard viewIfLoaded?.window != nil, let navigationController else { return }
            var ancestor = parent
            while let node = ancestor, node.parent !== navigationController { ancestor = node.parent }
            guard let ancestor, ancestor === navigationController.topViewController else { return }
            owner = ancestor
            install(navigationController.interactivePopGestureRecognizer)
            if #available(iOS 26.0, *) {
                install(navigationController.interactiveContentPopGestureRecognizer)
            }
            if backPan.view !== navigationController.view {
                navigationController.view.addGestureRecognizer(backPan)
            }
        }

        private func install(_ recognizer: UIGestureRecognizer?) {
            guard let recognizer, recognizer.delegate !== self else { return }
            let inherited = (recognizer.delegate as? Controller)?.gestures.first { $0.recognizer === recognizer }
            gestures.removeAll { $0.recognizer === recognizer }
            gestures.append(inherited ?? InstalledGesture(recognizer))
            recognizer.delegate = self
            recognizer.isEnabled = true
        }

        func detach() {
            backPan.view?.removeGestureRecognizer(backPan)
            for entry in gestures {
                guard let recognizer = entry.recognizer, recognizer.delegate === self else { continue }
                recognizer.delegate = entry.delegate
                recognizer.isEnabled = entry.wasEnabled
            }
            gestures.removeAll()
            owner = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let owner, let navigationController, owner === navigationController.topViewController,
                  navigationController.viewControllers.count > 1, navigationController.transitionCoordinator == nil,
                  navigationController.presentedViewController == nil else { return false }
            if gestureRecognizer === backPan {
                let translation = backPan.translation(in: backPan.view)
                let movement = translation == .zero ? backPan.velocity(in: backPan.view) : translation
                return HorizontalSwipeDirection(movement: movement) == .right
            }
            #if DEBUG
            if Self.testNativePopDeclines { return false }
            #endif
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled else { return false }
            if gestureRecognizer === navigationController?.interactivePopGestureRecognizer { return true }
            var touchedView = touch.view
            while let view = touchedView, view !== gestureRecognizer.view {
                if view is UIControl || view is UITextView { return false }
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
                   scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === backPan && other.isEnabled && gestures.contains { $0.recognizer === other }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other !== backPan, !gestures.contains(where: { $0.recognizer === other }) else { return false }
            guard let ownerView = owner?.viewIfLoaded, let otherView = other.view else { return false }
            return other is UIPanGestureRecognizer && otherView.isDescendant(of: ownerView)
        }

        @objc private func handleBackPan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, enabled, let view = pan.view, let owner, let navigationController,
                  owner === navigationController.topViewController, navigationController.viewControllers.count > 1,
                  navigationController.transitionCoordinator == nil,
                  navigationController.presentedViewController == nil else { return }
            let minimumDistance = max(56, min(100, view.bounds.width * 0.25))
            guard HorizontalSwipeDirection(movement: pan.translation(in: view), minimumDistance: minimumDistance) == .right else { return }
            pop?()
        }
    }
}
