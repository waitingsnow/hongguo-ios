import AVFoundation
import CoreImage
import SwiftUI
import UIKit

struct VideoFrameView: View {
    let image: UIImage

    var body: some View {
        Color.black.overlay {
            Image(uiImage: image).resizable().scaledToFit()
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

final class PlayerLayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onReadinessChange: ((AVPlayerItem?, Bool) -> Void)?
    var preparesFrameSnapshots = false

    private static let imageContext = CIContext()
    private var layerObservation: NSKeyValueObservation?
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private weak var reportedItem: AVPlayerItem?
    private var reportedReady: Bool?
    private var transformTask: Task<Void, Never>?
    private var frameTransform = CGAffineTransform.identity

    func setPlayer(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        layerObservation = nil
        playerObservation = nil
        itemObservation = nil
        transformTask?.cancel()
        frameTransform = .identity
        observedItem = nil
        reportedItem = nil
        reportedReady = nil
        playerLayer.player = player
        guard let player else { return }

        layerObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateReadiness() }
        }
        playerObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateReadiness() }
        }
    }

    private func updateReadiness() {
        let item = playerLayer.player?.currentItem
        if observedItem !== item {
            observedItem = item
            itemObservation = item?.observe(\.status, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateReadiness() }
            }
            if preparesFrameSnapshots { prepareFrameTransform(for: item) }
        }
        let ready = item?.status == .readyToPlay && playerLayer.isReadyForDisplay
        guard reportedItem !== item || reportedReady != ready else { return }
        reportedItem = item
        reportedReady = ready
        onReadinessChange?(item, ready)
    }

    private func prepareFrameTransform(for item: AVPlayerItem?) {
        transformTask?.cancel()
        frameTransform = .identity
        transformTask = item.map { item in
            Task { [weak self] in
                guard let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                      let transform = try? await track.load(.preferredTransform),
                      !Task.isCancelled else { return }
                self?.frameTransform = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c,
                                                          d: transform.d, tx: 0, ty: 0)
            }
        }
    }

    func snapshotDisplayedFrame(maxDimension: CGFloat? = nil) -> UIImage? {
        guard playerLayer.isReadyForDisplay else { return nil }
        let image: CGImage?
        if #available(iOS 27.0, *) {
            image = playerLayer.displayedReadOnlyPixelBuffer()?.withUnsafeBuffer { renderFrame($0, maxDimension: maxDimension) }
        } else {
            image = playerLayer.displayedPixelBuffer().flatMap { renderFrame($0, maxDimension: maxDimension) }
        }
        return image.map { UIImage(cgImage: $0) }
    }

    private func renderFrame(_ buffer: CVPixelBuffer, maxDimension: CGFloat?) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: frameTransform)
        if let maxDimension, max(image.extent.width, image.extent.height) > maxDimension {
            let scale = maxDimension / max(image.extent.width, image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return Self.imageContext.createCGImage(image, from: image.extent)
    }
}
