import SwiftUI

/// Hosts the swipe deck. Renders the current card with drag-to-decide
/// mechanics: dragging tilts the card, tints the screen, and shows a
/// Keep/Delete stamp; releasing past the threshold flings the card off-screen
/// and advances the deck, while a release below threshold springs everything
/// back. A bottom action bar holds the Review(N) entry point and undo.
struct SwipeView: View {
    @ObservedObject var service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    @StateObject private var viewModel: SwipeViewModel

    /// Live translation while the finger is down. Backed by GestureState so
    /// SwiftUI auto-resets it to `.zero` the moment the gesture ends — whether
    /// the user lifted, or the system cancelled it (e.g. a second finger
    /// landing). Combined with the `.interactiveSpring` modifier below, that
    /// reset animates as a spring-back so the card never sits stuck mid-drag.
    @GestureState private var dragTranslation: CGSize = .zero
    /// Held position for the off-screen fly animation after a committed swipe.
    @State private var exitOffset: CGSize = .zero
    @State private var isExiting = false
    @State private var showReviewSheet = false
    @State private var freedBannerDismiss: Task<Void, Never>?

    /// What we actually offset the card by. During the drag we follow the
    /// gesture; while flinging the card off-screen we switch to the explicit
    /// exit offset so the GestureState reset doesn't snap us back to center.
    private var displayOffset: CGSize {
        isExiting ? exitOffset : dragTranslation
    }

    init(service: PhotoLibraryService, store: ReviewStore) {
        self.service = service
        self.store = store
        self._viewModel = StateObject(wrappedValue: SwipeViewModel(store: store))
    }

    /// Horizontal distance (points) past which a release commits the swipe.
    private let swipeThreshold: CGFloat = 120
    /// How far off-screen the card flies before we swap in the next one.
    private let exitDistance: CGFloat = 1000

    var body: some View {
        ZStack(alignment: .top) {
            swipeTint
                .ignoresSafeArea()
                .allowsHitTesting(false)

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

            if let bytes = viewModel.lastFreedBytes {
                FreedBanner(bytes: bytes)
                    .padding(.top, 8)
                    .onTapGesture { dismissFreedBanner() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85),
                   value: viewModel.lastFreedBytes)
        .task {
            await viewModel.load(using: service)
        }
        .onChange(of: viewModel.lastFreedBytes) { newValue in
            scheduleFreedBannerDismiss(for: newValue)
        }
        .sheet(isPresented: $showReviewSheet) {
            DeleteReviewSheet(
                service: service,
                store: store,
                onConfirm: { await viewModel.confirmDelete(using: service) }
            )
        }
    }

    private func scheduleFreedBannerDismiss(for bytes: Int64?) {
        freedBannerDismiss?.cancel()
        guard bytes != nil else { return }
        freedBannerDismiss = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                viewModel.lastFreedBytes = nil
            }
        }
    }

    private func dismissFreedBanner() {
        freedBannerDismiss?.cancel()
        viewModel.lastFreedBytes = nil
    }

    // MARK: - Card

    private func card(for asset: PhotoAsset) -> some View {
        CardView(asset: asset, service: service)
            .overlay(alignment: .top) { cardStamps }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .offset(displayOffset)
            .rotationEffect(.degrees(Double(displayOffset.width / 18)))
            // Spring-back animation: when GestureState resets to .zero on
            // gesture end (lift OR cancellation), the card animates home.
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7),
                       value: dragTranslation)
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        handleDragEnd(translation: value.translation)
                    }
            )
            // Identity tied to the asset so SwiftUI rebuilds (and CardView's
            // .task reloads) when the deck advances.
            .id(asset.id)
    }

    /// Stamps that fade in with the swipe — Tinder-style direction cue.
    private var cardStamps: some View {
        HStack {
            stamp(text: "Delete", systemImage: "trash.fill", color: .red)
                .opacity(swipeProgress < 0 ? Double(-swipeProgress) : 0)
            Spacer()
            stamp(text: "Keep", systemImage: "checkmark", color: .green)
                .opacity(swipeProgress > 0 ? Double(swipeProgress) : 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .allowsHitTesting(false)
    }

    private func stamp(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text.uppercased())
        }
        .font(.title3.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color, in: Capsule())
        .shadow(color: color.opacity(0.4), radius: 6, y: 2)
    }

    /// Subtle full-screen tint that grows with the drag and squashes back on
    /// release through the same spring animation as `dragOffset`.
    private var swipeTint: some View {
        let progress = swipeProgress
        let tint: Color = progress > 0 ? .green : .red
        return tint.opacity(Double(abs(progress)) * 0.18)
    }

    private var swipeProgress: CGFloat {
        guard swipeThreshold > 0 else { return 0 }
        return max(-1, min(1, displayOffset.width / swipeThreshold))
    }

    // MARK: - Gesture handling

    private func handleDragEnd(translation: CGSize) {
        guard abs(translation.width) > swipeThreshold else {
            // GestureState resets automatically; the .animation modifier
            // springs the card back to centre.
            return
        }
        completeSwipe(translation: translation)
    }

    private enum SwipeDirection { case left, right }

    private func completeSwipe(translation: CGSize) {
        let direction: SwipeDirection = translation.width > 0 ? .right : .left
        let exitX: CGFloat = direction == .right ? exitDistance : -exitDistance

        // Anchor exitOffset to the lift-off point so swapping the displayOffset
        // source (dragTranslation → exitOffset) doesn't snap the card.
        exitOffset = translation
        isExiting = true
        withAnimation(.easeOut(duration: 0.25)) {
            exitOffset = CGSize(width: exitX, height: translation.height)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            // Batched state changes: VM advances and source flips back to
            // dragTranslation (0) in the same render cycle, so the next card
            // mounts centred — never visible at the exit position.
            switch direction {
            case .right: viewModel.keep()
            case .left:  viewModel.markForDeletion()
            }
            isExiting = false
            exitOffset = .zero
        }
    }

    // MARK: - Actions bar

    private var actionsBar: some View {
        HStack {
            if store.markedForDeletionIDs.count > 0 {
                Button {
                    showReviewSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill")
                        Text("Review (\(store.markedForDeletionIDs.count))")
                    }
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel("Review \(store.markedForDeletionIDs.count) photos pending deletion")
            }

            Spacer()

            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3.weight(.semibold))
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

    private var caughtUpPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(.largeTitle))
                .foregroundStyle(.green)
            Text("All caught up 🎉")
                .font(.title2.bold())
            Text("That's the end of your library.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Transient "Freed ~X MB" banner shown after a successful batch delete.
private struct FreedBanner: View {
    let bytes: Int64

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.green)
            Text("Freed ~\(Self.formatter.string(fromByteCount: bytes))")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Freed approximately \(Self.formatter.string(fromByteCount: bytes))")
    }
}
