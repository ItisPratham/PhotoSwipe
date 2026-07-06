import AVFoundation
import SwiftUI

/// Video variant of the swipe card. Mirrors `CardView`'s framing, rounding, and
/// date label, but plays the clip: the poster thumbnail shows first (fast,
/// local), then a muted, looping autoplay of the current card fades in on top.
/// Tapping toggles play/pause; a duration badge sits top-trailing; and a
/// scrubber along the bottom seeks forward/backward like the Photos app.
///
/// Playback lives in a small `VideoPlaybackController` (player, looper, time
/// observer, seeking) so the view stays declarative. Only the visible card
/// holds a controller — built in `.task(id:)`, torn down in `onDisappear` — so
/// advancing the deck releases the AV resources.
struct VideoCardView: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @StateObject private var controller = VideoPlaybackController()
    @State private var poster: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mediaLayer
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if !controller.isPlaying {
                    playIndicator
                }
            }
            .overlay(alignment: .topLeading) { dateLabel }
            .overlay(alignment: .topTrailing) { durationBadge }
            .overlay(alignment: .bottom) { scrubber }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
            .contentShape(Rectangle())
            .onTapGesture { controller.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Video from \(asset.formattedDate), \(asset.formattedDuration)"))
            .accessibilityAddTraits(.startsMediaSession)
            .task(id: asset.id) {
                await start(targetSize: targetPixelSize(from: proxy.size))
            }
            .onDisappear { controller.teardown() }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var mediaLayer: some View {
        ZStack {
            // Poster stays behind the video layer so there's never a blank
            // frame while the player buffers.
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let player = controller.player {
                PlayerLayerView(player: player)
            }
        }
    }

    private var playIndicator: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 64))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.35))
            .shadow(color: .black.opacity(0.3), radius: 8)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    private var dateLabel: some View {
        Text(asset.formattedDate)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(16)
    }

    private var durationBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "video.fill")
                .font(.caption2)
            Text(asset.formattedDuration)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(16)
    }

    // MARK: - Scrubber

    /// Bottom seek bar. Its drag is a descendant gesture, so it takes priority
    /// over the parent swipe-to-decide drag — dragging the bar seeks the clip
    /// rather than flinging the card. A zero-distance drag also handles taps to
    /// seek to a point.
    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = controller.progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * progress), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .offset(x: width * progress - 7)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.beginScrubbing()
                        controller.scrub(toFraction: value.location.x / width)
                    }
                    .onEnded { value in
                        controller.scrub(toFraction: value.location.x / width)
                        controller.endScrubbing()
                    }
            )
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Lifecycle

    private func start(targetSize: CGSize) async {
        poster = nil
        // Poster and player load concurrently; the player never waits on the
        // poster stream finishing, and cancelling the task cancels both.
        async let posterLoad: Void = loadPoster(targetSize: targetSize)
        let item = await service.playerItem(for: asset)
        if let item {
            controller.start(item: item, duration: asset.duration)
        }
        _ = await posterLoad
    }

    private func loadPoster(targetSize: CGSize) async {
        for await next in service.imageStream(for: asset, targetSize: targetSize) {
            poster = next
        }
    }

    private func targetPixelSize(from size: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Owns the AVQueuePlayer + looper and the periodic time observer that drives
/// the scrubber. Muted, looping playback; seeking is precise (zero tolerance)
/// so scrubbing lands where the finger is. Not `@MainActor`-annotated for iOS
/// 16 compatibility — every entry point is called from the main actor and the
/// time observer fires on the main queue.
final class VideoPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var duration: Double = 0
    private var isScrubbing = false

    /// 0…1 playback position for the scrubber fill/knob.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func start(item: AVPlayerItem, duration: Double) {
        self.duration = duration
        // Ambient so a silent-but-playing preview mixes with (rather than
        // stops) any audio the user has going, and respects the silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)

        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        addTimeObserver(to: queue)
        queue.play()
        isPlaying = true
    }

    private func addTimeObserver(to player: AVQueuePlayer) {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = time.seconds
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isPlaying.toggle()
        }
    }

    func beginScrubbing() { isScrubbing = true }

    func scrub(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        currentTime = clamped * duration
        seek(to: clamped * duration)
    }

    func endScrubbing() { isScrubbing = false }

    private func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func teardown() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

/// Thin `AVPlayerLayer` host — aspect-fit to match `CardView`'s `scaledToFit`,
/// no playback controls (the card owns tap-to-toggle and the scrubber).
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
