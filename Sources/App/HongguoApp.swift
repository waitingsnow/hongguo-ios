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
        .fullScreenCover(item: $model.playback) { request in PlayerScreen(request: request, model: model).environmentObject(library) }
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
                .background(NavigationBackSwipe())
                .navigationDestination(for: Drama.self) { DetailView(drama: $0) }
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

struct NavigationBackSwipe: UIViewControllerRepresentable {
    var dismissRoot: (() -> Void)?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.dismissRoot = dismissRoot
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detachPan()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var dismissRoot: (() -> Void)?
        private weak var startController: UIViewController?
        private lazy var backPan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()

        override func loadView() {
            let marker = UIView()
            marker.isUserInteractionEnabled = false
            view = marker
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attachPan()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachPan()
        }

        private func attachPan() {
            let target = navigationController?.view
            guard backPan.view !== target else { return }
            detachPan()
            target?.addGestureRecognizer(backPan)
        }

        func detachPan() {
            backPan.view?.removeGestureRecognizer(backPan)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController, navigationController.transitionCoordinator == nil,
                  navigationController.viewControllers.count > 1 || dismissRoot != nil,
                  HorizontalSwipeDirection(movement: backPan.velocity(in: backPan.view)) == .right else { return false }
            startController = navigationController.topViewController
            return startController != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView, view !== backPan.view {
                if view is UIControl || view is UITextView { return false }
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
                   scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            if other === navigationController.interactivePopGestureRecognizer { return true }
            if #available(iOS 26.0, *) { return other === navigationController.interactiveContentPopGestureRecognizer }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (other.view as? UIScrollView)?.panGestureRecognizer === other
        }

        @objc private func swiped(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let navigationController, let startController,
                  startController === navigationController.topViewController, navigationController.transitionCoordinator == nil,
                  HorizontalSwipeDirection.right.completes(pan.translation(in: pan.view)) else { return }
            if navigationController.viewControllers.count > 1 { navigationController.popViewController(animated: true) }
            else { dismissRoot?() }
        }
    }
}
