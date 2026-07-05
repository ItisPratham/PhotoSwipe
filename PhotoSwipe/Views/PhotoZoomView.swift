import SwiftUI

/// Fullscreen photo viewer used to inspect the current swipe card. Loaded on
/// pinch-out from SwipeView. Supports further pinch-to-zoom (1×–4×), pan when
/// zoomed, and dismiss via the top-trailing close button or a downward drag.
///
/// Deliberately keeps the swipe / mark / delete flow on the card view — this
/// is a read-only inspector, no decisions made here.
struct PhotoZoomView: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var image: UIImage?

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinchScale: CGFloat = 1.0

    @State private var offset: CGSize = .zero

    /// Offset committed at the start of the current pan; the live drag
    /// translation is added to this and rubber-banded past the edges.
    @State private var panBase: CGSize = .zero
    @State private var isPanning = false

    /// Container size, captured so pan can be clamped to the image's edges.
    @State private var containerSize: CGSize = .zero

    /// Tracks a downward drag when NOT zoomed — used to dismiss.
    @GestureState private var dismissDrag: CGFloat = 0
    private let dismissThreshold: CGFloat = 140

    @Environment(\.dismiss) private var dismiss

    private var effectiveScale: CGFloat {
        max(1.0, min(4.0, scale * pinchScale))
    }

    private var isZoomed: Bool { effectiveScale > 1.01 }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .opacity(1 - min(dismissDrag / dismissThreshold, 1) * 0.6)

            imageLayer
                .scaleEffect(effectiveScale)
                .offset(x: offset.width,
                        y: offset.height + dismissDrag)
                .gesture(magnificationGesture)
                .simultaneousGesture(panGesture)
                .simultaneousGesture(dismissGesture)
                .onTapGesture(count: 2) { toggleZoom() }

            dismissButton
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { containerSize = $0 }
            }
        )
        .task(id: asset.id) {
            for await next in service.imageStream(
                for: asset,
                targetSize: CGSize(width: 2400, height: 2400)
            ) {
                image = next
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Layers

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var dismissButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(12)
                }
                .accessibilityLabel("Close photo viewer")
            }
            Spacer()
        }
        // Fade the chrome as the user drags to dismiss.
        .opacity(1 - min(dismissDrag / dismissThreshold, 1))
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = max(1.0, min(4.0, scale * value))
                if scale < 1.05 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        scale = 1.0
                        offset = .zero
                    }
                } else {
                    // Zooming out reduces the pannable area — pull the image
                    // back within its new bounds so it can't sit off-screen.
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                        offset = clampedOffset(offset, scale: scale)
                    }
                }
            }
    }

    /// Pan only kicks in while the image is zoomed. That way an ungainly
    /// horizontal swipe on a 1× photo doesn't accidentally shift it — only
    /// the dedicated dismissGesture is active.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                if !isPanning {
                    isPanning = true
                    panBase = offset
                }
                let proposed = CGSize(
                    width: panBase.width + value.translation.width,
                    height: panBase.height + value.translation.height
                )
                // Follow the finger, but apply increasing resistance past the
                // edges so the photo can drift only slightly out of frame.
                offset = rubberBanded(proposed, scale: effectiveScale)
            }
            .onEnded { value in
                isPanning = false
                guard isZoomed else { return }
                let proposed = CGSize(
                    width: panBase.width + value.translation.width,
                    height: panBase.height + value.translation.height
                )
                // Ease back to the nearest in-bounds position — short travel
                // now, so the settle reads as a gentle nudge, not a snap.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    offset = clampedOffset(proposed, scale: effectiveScale)
                }
            }
    }

    /// Downward-drag-to-dismiss when NOT zoomed — matches Photos / Messages
    /// conventions. Horizontal or upward drag is ignored.
    private var dismissGesture: some Gesture {
        DragGesture()
            .updating($dismissDrag) { value, state, _ in
                guard !isZoomed else { return }
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed else { return }
                if value.translation.height > dismissThreshold {
                    dismiss()
                }
            }
    }

    // MARK: - Pan bounds

    /// The on-screen size of the `scaledToFit` image at 1× (before zoom),
    /// derived from the photo's aspect ratio and the container size.
    private func fittedImageSize() -> CGSize {
        guard let image,
              image.size.width > 0, image.size.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return containerSize
        }
        let imageAspect = image.size.width / image.size.height
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect > containerAspect {
            // Constrained by width.
            return CGSize(width: containerSize.width,
                          height: containerSize.width / imageAspect)
        } else {
            // Constrained by height.
            return CGSize(width: containerSize.height * imageAspect,
                          height: containerSize.height)
        }
    }

    /// How far the image may travel from centre on each axis at a given scale:
    /// half the overflow beyond the container. Zero when the image fits.
    private func maxOffset(for scale: CGFloat) -> CGSize {
        let fitted = fittedImageSize()
        return CGSize(
            width: max(0, (fitted.width * scale - containerSize.width) / 2),
            height: max(0, (fitted.height * scale - containerSize.height) / 2)
        )
    }

    private func clampedOffset(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let limit = maxOffset(for: scale)
        return CGSize(
            width: min(max(proposed.width, -limit.width), limit.width),
            height: min(max(proposed.height, -limit.height), limit.height)
        )
    }

    /// Position with progressive resistance beyond the pannable bounds, so a
    /// hard drag only nudges the photo slightly out of frame instead of hitting
    /// a wall or flying off. Mirrors UIScrollView's rubber-band curve.
    private func rubberBanded(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let limit = maxOffset(for: scale)
        return CGSize(
            width: rubberBand(proposed.width, limit: limit.width, dimension: containerSize.width),
            height: rubberBand(proposed.height, limit: limit.height, dimension: containerSize.height)
        )
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat, dimension: CGFloat) -> CGFloat {
        guard abs(value) > limit, dimension > 0 else { return value }
        let sign: CGFloat = value < 0 ? -1 : 1
        let excess = abs(value) - limit
        let constant: CGFloat = 0.55
        let damped = (1 - (1 / (excess * constant / dimension + 1))) * dimension
        return sign * (limit + damped)
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if isZoomed {
                scale = 1.0
                offset = .zero
            } else {
                scale = 2.5
            }
        }
    }
}
