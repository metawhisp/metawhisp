import AVFoundation
import AVKit
import AppKit
import SwiftUI

/// 5th pill style — animated dancing-Shrek video. User-spec 2026-05-02.
///
/// Stage → playback rate / color:
///   - .idle           → 0.4× (lazy wobble)
///   - .recording      → 1.0× (normal dance)
///   - .processing     → 0.35× (slowed) + smooth red tint
///   - .postProcessing → 2.0× (sped-up celebration), color back to normal
///
/// Speed is controlled via `AVPlayer.rate` on the bundled HEVC `.mov` (alpha
/// channel preserved — the video is transparent around Shrek). Color tint is
/// a SwiftUI `Color.red` overlay with `.sourceAtop` blend mode so only the
/// visible silhouette gets red'd, not the transparent background.
struct ShrekPillView: View {
    let stage: TranscriptionCoordinator.Stage
    let isTranslating: Bool

    /// Animatable red intensity. 0 = no tint, 1 = fully red. Driven by
    /// `.onChange(of: stage)` with an 800ms ease curve so the colour fades
    /// in/out instead of snapping.
    @State private var redIntensity: CGFloat = 0

    private var targetRate: Float {
        switch stage {
        case .idle:           return 0.4
        case .recording:      return 1.0
        case .processing:     return 0.35   // transcribing
        case .postProcessing: return 2.0    // answered / translating
        }
    }

    private var targetRedIntensity: CGFloat {
        // Only transcribing turns red; everything else clears.
        stage == .processing ? 0.55 : 0
    }

    var body: some View {
        // `TimelineView(.animation)` forces SwiftUI to re-evaluate body on
        // every display frame. Without it, `.compositingGroup()` rasterises
        // the ZStack ONCE into an offscreen buffer and reuses that buffer
        // forever — but `AVPlayerLayer` inside updates its contents
        // independently via the player's display link, so SwiftUI never
        // invalidates the buffer. Result: the FIRST FRAME of the alpha
        // video stays baked into the compositing buffer and follows the
        // animated Shrek as a ghost halo around his perimeter (user report
        // 2026-05-02: "шлейф остается, движется с ним, статичный").
        // TimelineView re-runs body 60 fps → buffer reraster every frame → no ghost.
        TimelineView(.animation) { _ in
            ZStack {
                ShrekVideoLayer(rate: targetRate)
                Color.red
                    .opacity(redIntensity)
                    .blendMode(.sourceAtop)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .frame(width: 200, height: 200)
        }
        .onAppear { redIntensity = targetRedIntensity }
        .onChange(of: stage) { _, _ in
            withAnimation(.easeInOut(duration: 0.8)) {
                redIntensity = targetRedIntensity
            }
        }
    }
}

/// `NSViewRepresentable` wrapping `AVPlayerLayer` so SwiftUI can host the
/// looping HEVC video. Keeps a single `AVPlayer` per view instance (no
/// per-update teardown) and just sets `player.rate` when the prop changes.
private struct ShrekVideoLayer: NSViewRepresentable {
    let rate: Float

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        // Host layer must be non-opaque AND non-redraw-caching, otherwise the
        // first frame of the alpha-channel video bakes into the layer and
        // shows as a ghost trail behind the dancing Shrek (user report
        // 2026-05-02). `layerContentsRedrawPolicy = .duringViewResize`
        // ensures the layer doesn't preserve old contents between frames.
        let host = CALayer()
        host.isOpaque = false
        host.backgroundColor = NSColor.clear.cgColor
        container.layer = host
        container.layerContentsRedrawPolicy = .duringViewResize

        // `Bundle.module` collides with `swift-transformers/Hub.module` in this
        // Swift package's import graph (both declare an internal accessor with
        // the same selector), so the compiler picks the dependency's and
        // refuses access. Anchor the bundle via the Coordinator class — that's
        // unambiguously the MetaWhisp target so resources copied via
        // `.copy("Resources/shrek-pill.mov")` resolve correctly.
        let bundle = Bundle(for: Coordinator.self)
        guard let url = bundle.url(forResource: "shrek-pill", withExtension: "mov")
            ?? Bundle.main.url(forResource: "shrek-pill", withExtension: "mov") else {
            NSLog("[ShrekPill] ❌ shrek-pill.mov missing from bundle")
            return container
        }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = AVPlayer.ActionAtItemEnd.none
        player.isMuted = true
        // No automatic pause when route changes / app backgrounds — recording
        // pill should keep dancing whenever the overlay is visible.
        player.preventsDisplaySleepDuringVideoPlayback = false

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        playerLayer.frame = container.bounds
        playerLayer.autoresizingMask = [CAAutoresizingMask.layerWidthSizable, CAAutoresizingMask.layerHeightSizable]
        // Force BGRA pixel buffer so the alpha channel from the HEVC source
        // is preserved. Default format on macOS sometimes drops alpha,
        // producing a ghost trail of the first frame in transparent regions.
        playerLayer.pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        playerLayer.isOpaque = false
        playerLayer.backgroundColor = NSColor.clear.cgColor
        container.layer?.addSublayer(playerLayer)

        // Loop manually — `actionAtItemEnd = .none` + observer to restart.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        player.play()
        player.rate = rate
        context.coordinator.player = player
        context.coordinator.observer = observer
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Apply new rate ONLY if changed — avoids restarting the video on
        // unrelated SwiftUI re-renders. `rate` and `pause()` interact (pause
        // sets rate to 0), so we always re-set rate explicitly here.
        let player = context.coordinator.player
        if player?.rate != rate {
            player?.rate = rate
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.player?.pause()
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.player = nil
        coordinator.observer = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVPlayer?
        var observer: NSObjectProtocol?
    }
}
