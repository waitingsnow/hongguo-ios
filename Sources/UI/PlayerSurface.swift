import AVKit
import Combine
import SwiftUI
import UIKit

/// One picture layer for the whole player screen, including 小窗播放 during episode changes.
@MainActor
final class PlayerSurface: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    enum PiPPhase {
        case idle, starting, active
    }

    let view = PlayerLayerHost()
    @Published private(set) var displayedPlayID: UUID?
    @Published private(set) var heldFrame: UIImage?
    @Published private(set) var pipPhase: PiPPhase = .idle
    var pipInProgress: Bool { pipPhase != .idle }
    var pipActive: Bool { pipPhase == .active }
    var onPiPEnd: (() -> Void)?
    private var pip: AVPictureInPictureController?
    private var playerSubscription: AnyCancellable?
    private var playIDSubscription: AnyCancellable?
    private weak var session: PlayerSession?

    override init() {
        super.init()
        view.isOpaque = false
        view.preparesFrameSnapshots = true
        view.playerLayer.videoGravity = .resizeAspect
    }

    var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func bind(_ session: PlayerSession) {
        guard self.session !== session else { return }
        self.session = session
        view.onReadinessChange = { [weak self, weak session] item, ready in
            guard ready, let item, let self, let ticket = session?.firstFrame(for: item) else { return }
            guard self.displayedPlayID != ticket else { return }
            self.displayedPlayID = ticket
            self.heldFrame = nil
        }
        playIDSubscription = session.$playID.dropFirst().sink { [weak self, weak session] _ in
            guard let self, let session else { return }
            if session.currentPlaybackItem == nil { self.holdDisplayedFrame(ticket: session.playID) }
        }
        playerSubscription = session.$player.sink { [weak self] player in self?.view.setPlayer(player) }
        guard pip == nil, pipSupported, let controller = AVPictureInPictureController(playerLayer: view.playerLayer) else { return }
        controller.delegate = self
        // Leaving the app while an episode plays continues it in the small window. Users can turn this off in
        // the system's 画中画 settings.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
    }

    func holdDisplayedFrame(ticket: UUID) {
        guard displayedPlayID == ticket, !pipInProgress,
              UIApplication.shared.applicationState != .background,
              let frame = view.snapshotDisplayedFrame() else { return }
        heldFrame = frame
    }

    func releaseHeldFrame(ticket: UUID) {
        if displayedPlayID == ticket { heldFrame = nil }
    }

    func unbind() {
        pip?.stopPictureInPicture()
        pip?.delegate = nil; pip = nil
        playerSubscription = nil; playIDSubscription = nil
        view.onReadinessChange = nil
        view.setPlayer(nil)
        heldFrame = nil; displayedPlayID = nil
        onPiPEnd = nil; pipPhase = .idle; session = nil
    }

    func stopPictureInPicture() { pip?.stopPictureInPicture() }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.pip === controller, self.pipPhase == .idle else { return }
            self.pipPhase = .starting
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.pip === controller else { return }
            self.pipPhase = .active
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.endPictureInPicture(controller) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.endPictureInPicture(controller) }
    }

    private func endPictureInPicture(_ controller: AVPictureInPictureController) {
        guard pip === controller else { return }
        pipPhase = .idle
        onPiPEnd?()
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen stays presented underneath, so there is nothing to rebuild.
        completionHandler(true)
    }
}

/// A layer of its own per player, for the home feed's previews.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var onReadyForDisplayChange: ((Bool) -> Void)? = nil
    let onFirstFrame: (PlayerLayerHost) -> Void

    func makeUIView(context: Context) -> PlayerLayerHost {
        let view = PlayerLayerHost()
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHost, context: Context) {
        uiView.onReadinessChange = { [weak uiView] _, ready in
            onReadyForDisplayChange?(ready)
            if ready, let uiView { onFirstFrame(uiView) }
        }
        uiView.setPlayer(player)
    }

    static func dismantleUIView(_ uiView: PlayerLayerHost, coordinator: ()) {
        uiView.onReadinessChange = nil
        uiView.setPlayer(nil)
    }
}

struct PlayerSurfaceView: UIViewRepresentable {
    let surface: PlayerSurface
    func makeUIView(context: Context) -> PlayerLayerHost { surface.view }
    func updateUIView(_ uiView: PlayerLayerHost, context: Context) { }
}

@MainActor
enum InterfaceOrientationLock {
    private static weak var lockedScene: UIWindowScene?
    private static var lockedMask: UIInterfaceOrientationMask = .allButUpsideDown

    static func supportedOrientations(in scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let scene, scene === lockedScene else { return .allButUpsideDown }
        return lockedMask
    }

    static func lockLandscape(in scene: UIWindowScene) -> Bool {
        let orientation = scene.effectiveGeometry.interfaceOrientation
        switch orientation {
        case .landscapeLeft: lockedMask = .landscapeLeft
        case .landscapeRight: lockedMask = .landscapeRight
        default: return false
        }
        lockedScene = scene
        invalidate(in: scene)
        return true
    }

    static func unlock() {
        guard let scene = lockedScene else { return }
        lockedScene = nil
        invalidate(in: scene)
    }

    private static func invalidate(in scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller { current.setNeedsUpdateOfSupportedInterfaceOrientations(); controller = current.presentedViewController }
        }
    }
}

final class HongguoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { InterfaceOrientationLock.supportedOrientations(in: window?.windowScene) }
    }
}

enum SpeedLockZone {
    case upper, lower

    init(start: CGPoint, bounds: CGRect) {
        self = start.y >= bounds.midY ? .upper : .lower
    }

    func frame(in bounds: CGRect) -> CGRect {
        let height = min(52, bounds.height * 0.28)
        let center = bounds.minY + bounds.height * (self == .upper ? 0.25 : 0.68)
        return CGRect(x: bounds.minX, y: center - height / 2, width: bounds.width, height: height)
    }
}

struct HoldDrag {
    enum Update {
        case startedSeeking
        case seeking(CGFloat)
        case lockSpeed
    }

    private enum Mode {
        case undecided, vertical, horizontal(anchor: CGFloat), consumed
    }

    private let start: CGPoint
    private let zone: SpeedLockZone?
    private var mode: Mode = .undecided

    init(start: CGPoint, zone: SpeedLockZone?) {
        self.start = start
        self.zone = zone
    }

    mutating func update(at point: CGPoint, in bounds: CGRect) -> Update? {
        switch mode {
        case .undecided:
            let horizontal = abs(point.x - start.x)
            let vertical = abs(point.y - start.y)
            if horizontal > 10, horizontal > vertical * 1.2 {
                mode = .horizontal(anchor: point.x)
                return .startedSeeking
            }
            guard vertical > 10, vertical > horizontal * 1.2 else { return nil }
            mode = .vertical
            fallthrough
        case .vertical:
            guard let zone, zone.frame(in: bounds).contains(point) else { return nil }
            mode = .consumed
            return .lockSpeed
        case .horizontal:
            return seekFraction(at: point, width: bounds.width).map(Update.seeking)
        case .consumed:
            return nil
        }
    }

    func seekFraction(at point: CGPoint, width: CGFloat) -> CGFloat? {
        guard case let .horizontal(anchor) = mode, width > 0 else { return nil }
        return (point.x - anchor) / width
    }
}

struct VideoGestureView: UIViewRepresentable {
    let enabled: Bool
    let locked: Bool
    let tap: (CGFloat) -> Void
    let doubleTap: (CGFloat) -> Void
    let holdBegan: (SpeedLockZone) -> Bool
    let holdEnded: () -> Void
    let lockSpeed: () -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat, CGFloat) -> Void
    let dragCancelled: () -> Void
    let navigate: (HorizontalSwipeDirection) -> Void
    let seekChanged: (CGFloat) -> Void
    let seekEnded: (CGFloat) -> Void
    let seekCancelled: () -> Void
    let pinched: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))); hold.minimumPressDuration = 0.35; hold.allowableMovement = 18
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2; doubleTap.require(toFail: hold)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))); tap.require(toFail: hold); tap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:))); pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        doubleTap.require(toFail: pan)
        tap.require(toFail: pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinchChanged(_:)))
        let recognizers: [UIGestureRecognizer] = [hold, doubleTap, tap, pan, pinch]
        context.coordinator.singleTap = tap
        recognizers.forEach { view.addGestureRecognizer($0) }
        apply(to: view, coordinator: context.coordinator)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        apply(to: uiView, coordinator: context.coordinator)
    }
    private func apply(to view: UIView, coordinator: Coordinator) {
        view.gestureRecognizers?.forEach { recognizer in
            let on = enabled && (!locked || recognizer === coordinator.singleTap)
            if recognizer.isEnabled != on { recognizer.isEnabled = on }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.parent.holdEnded() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: VideoGestureView
        weak var singleTap: UIGestureRecognizer?
        private var pinchDecided = false
        private var holdDrag: HoldDrag?
        private var navigationDirection: HorizontalSwipeDirection?

        init(_ parent: VideoGestureView) { self.parent = parent }

        @objc func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { pinchDecided = false }
            guard gesture.state == .changed, !pinchDecided, gesture.scale >= 1.18 || gesture.scale <= 0.85 else { return }
            pinchDecided = true
            parent.pinched(gesture.scale > 1)
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) { if let x = fraction(gesture) { parent.tap(x) } }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) { if let x = fraction(gesture) { parent.doubleTap(x) } }
        private func fraction(_ gesture: UIGestureRecognizer) -> CGFloat? {
            guard let view = gesture.view, view.bounds.width > 0 else { return nil }
            return gesture.location(in: view).x / view.bounds.width
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                let zone = SpeedLockZone(start: point, bounds: view.bounds)
                holdDrag = HoldDrag(start: point, zone: parent.holdBegan(zone) ? zone : nil)
            case .changed:
                switch holdDrag?.update(at: point, in: view.bounds) {
                case .startedSeeking:
                    parent.holdEnded()
                    UISelectionFeedbackGenerator().selectionChanged()
                    parent.seekChanged(0)
                case let .seeking(fraction): parent.seekChanged(fraction)
                case .lockSpeed: parent.lockSpeed()
                case nil: break
                }
            case .ended:
                if let fraction = holdDrag?.seekFraction(at: point, width: view.bounds.width) {
                    parent.seekEnded(fraction)
                } else if case .lockSpeed = holdDrag?.update(at: point, in: view.bounds) {
                    parent.lockSpeed()
                }
                parent.holdEnded()
                holdDrag = nil
            case .cancelled, .failed:
                if holdDrag?.seekFraction(at: point, width: view.bounds.width) != nil {
                    let cancel = parent.seekCancelled
                    Task { @MainActor in cancel() }
                }
                parent.holdEnded()
                holdDrag = nil
            default: break
            }
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if let direction = navigationDirection {
                if gesture.state == .ended, direction.completes(gesture.translation(in: view)) {
                    parent.navigate(direction)
                }
                return
            }
            switch gesture.state {
            case .began, .changed: parent.dragChanged(gesture.translation(in: view).y)
            case .ended: parent.dragEnded(gesture.translation(in: view).y, gesture.velocity(in: view).y)
            case .cancelled, .failed: parent.dragCancelled()
            default: break
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            navigationDirection = nil
            guard holdDrag == nil, pan.numberOfTouches <= 1 else { return false }
            let velocity = pan.velocity(in: view)
            if abs(velocity.y) > abs(velocity.x) { return true }
            navigationDirection = HorizontalSwipeDirection(movement: velocity)
            return navigationDirection != nil
        }
    }
}
