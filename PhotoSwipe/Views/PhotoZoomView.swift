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
    @GestureState private var dragOffset: CGSize = .zero

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
                .offset(x: offset.width + dragOffset.width,
                        y: offset.height + dragOffset.height + dismissDrag)
                .scaleEffect(effectiveScale)
                .gesture(magnificationGesture)
                .simultaneousGesture(panGesture)
                .simultaneousGesture(dismissGesture)
                .onTapGesture(count: 2) { toggleZoom() }

            dismissButton
        }
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
                }
            }
    }

    /// Pan only kicks in while the image is zoomed. That way an ungainly
    /// horizontal swipe on a 1× photo doesn't accidentally shift it — only
    /// the dedicated dismissGesture is active.
    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                if isZoomed { state = value.translation }
            }
            .onEnded { value in
                if isZoomed {
                    offset = CGSize(
                        width: offset.width + value.translation.width,
                        height: offset.height + value.translation.height
                    )
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
