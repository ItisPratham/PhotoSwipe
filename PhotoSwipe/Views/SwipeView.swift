import SwiftUI

/// Hosts the swipe deck. Renders the current card with drag-to-decide
/// mechanics: dragging tilts the card, releasing past the threshold flings it
/// off-screen and advances the deck. A bottom action bar holds the single-step
/// undo (and, in M7, the Delete(N) button).
struct SwipeView: View {
    @ObservedObject var service: PhotoLibraryService
    @StateObject private var viewModel: SwipeViewModel

    @State private var dragOffset: CGSize = .zero

    init(service: PhotoLibraryService, store: ReviewStore) {
        self.service = service
        self._viewModel = StateObject(wrappedValue: SwipeViewModel(store: store))
    }

    /// Horizontal distance (points) past which a release commits the swipe.
    private let swipeThreshold: CGFloat = 120
    /// How far off-screen the card flies before we swap in the next one.
    private let exitDistance: CGFloat = 1000

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading library…")
                        .controlSize(.large)
                } else if let asset = viewModel.currentAsset {
                    card(for: asset)
                } else {
                    caughtUpPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !viewModel.isLoading {
                actionsBar
            }
        }
        .task {
            await viewModel.load(using: service)
        }
    }

    private var actionsBar: some View {
        HStack {
            Spacer()
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.thinMaterial, in: Circle())
            }
            .disabled(!viewModel.canUndo)
            .opacity(viewModel.canUndo ? 1 : 0.35)
            .accessibilityLabel("Undo last swipe")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func card(for asset: PhotoAsset) -> some View {
        CardView(asset: asset, service: service)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .offset(dragOffset)
            .rotationEffect(.degrees(Double(dragOffset.width / 18)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        handleDragEnd(translation: value.translation)
                    }
            )
            // Identity tied to the asset so SwiftUI rebuilds (and CardView's
            // .task reloads) when the deck advances.
            .id(asset.id)
    }

    private func handleDragEnd(translation: CGSize) {
        if translation.width > swipeThreshold {
            completeSwipe(.right)
        } else if translation.width < -swipeThreshold {
            completeSwipe(.left)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                dragOffset = .zero
            }
        }
    }

    private enum SwipeDirection { case left, right }

    private func completeSwipe(_ direction: SwipeDirection) {
        let exitX: CGFloat = direction == .right ? exitDistance : -exitDistance
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: exitX, height: dragOffset.height)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch direction {
            case .right: viewModel.keep()
            case .left:  viewModel.markForDeletion()
            }
            // New card mounts because of the .id(asset.id), so we can drop the
            // offset without animation — the incoming card starts centered.
            dragOffset = .zero
        }
    }

    private var caughtUpPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("All caught up 🎉")
                .font(.title2.bold())
            Text("That's the end of your library.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
