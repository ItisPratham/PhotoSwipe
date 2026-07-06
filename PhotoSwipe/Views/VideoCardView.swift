import AVFoundation
import SwiftUI

/// Video variant of the swipe card. Mirrors `CardView`'s framing, rounding, and
/// date label, but plays the clip: the poster thumbnail shows first (fast,
/// local), then a muted, looping autoplay of the current card fades in on top.
/// Tapping toggles play/pause; a duration badge sits in the top-trailing corner.
///
/// Only the visible card ever holds a player — it's built in `.task(id:)` and
/// torn down in `onDisappear`, so advancing the deck releases the AV resources.
struct VideoCardView: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var poster: UIImage?
    @State private var player: AVQueuePlayer?
    /// Retained so the loop keeps running; releasing it stops the looping.
    @State private var looper: AVPlayerLooper?
    @State private var isPlaying = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                mediaLayer
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if !isPlaying {
                    playIndicator
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                dateLabel
            }
            .overlay(alignment: .topTrailing) { durationBadge }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
            .contentShape(Rectangle())
            .onTapGesture { togglePlayback() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Video from \(asset.formattedDate), \(asset.formattedDuration)"))
            .accessibilityAddTraits(.startsMediaSession)
            .task(id: asset.id) {
                await start(targetSize: targetPixelSize(from: proxy.size))
            }
            .onDisappear(perform: teardown)
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

            if let player {
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

    // MARK: - Playback

    private func start(targetSize: CGSize) async {
        poster = nil
        // Poster and player load concurrently; the player never waits on the
        // poster stream finishing, and cancelling the task cancels both.
        async let posterLoad: Void = loadPoster(targetSize: targetSize)
        let item = await service.playerItem(for: asset)

        if let item {
            configureAudioSession()
            let queue = AVQueuePlayer()
            queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()
            isPlaying = true
        }

        _ = await posterLoad
    }

    private func loadPoster(targetSize: CGSize) async {
        for await next in service.imageStream(for: asset, targetSize: targetSize) {
            poster = next
        }
    }

    private func togglePlayback() {
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

    private func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
    }

    /// Ambient so a silent-but-playing preview mixes with (rather than stops)
    /// any audio the user already has going, and respects the ring/silent switch.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
    }

    private func targetPixelSize(from size: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Thin `AVPlayerLayer` host — aspect-fit to match `CardView`'s `scaledToFit`,
/// no playback controls (the card owns tap-to-toggle).
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
