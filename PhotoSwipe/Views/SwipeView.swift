import SwiftUI

/// Hosts the swipe deck. Renders the current card with drag-to-decide
/// mechanics: dragging tilts the card, tints the screen, and shows a
/// Keep/Delete stamp; releasing past the threshold flings the card off-screen
/// and advances the deck, while a release below threshold springs everything
/// back. A bottom action bar holds the Review(N) entry point and undo.
struct SwipeView: View {
    /// Observed: the body reacts to `libraryVersion`.
    @ObservedObject var service: PhotoLibraryService
    /// Observed: the body reads the reviewed and marked counts.
    @ObservedObject var store: ReviewStore
    /// Not observed: only passed to the view model.
    let stats: StatsStore
    let sizes: SizeStore
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
    @State private var zoomAsset: PhotoAsset?
    @State private var freedBannerDismiss: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    /// What swipe-up does; chosen in Settings.
    @AppStorage(SwipeUpAction.storageKey) private var swipeUpRaw = "favorite"
    private var swipeUpAction: SwipeUpAction {
        switch swipeUpRaw {
        default: return .favorite
        }
    }

    /// How many cards past the current one are kept warm in the image cache.
    /// Small on purpose: each entry is a screen-sized decoded image.
    private let prefetchDepth = 3
    /// Pixel size the cards request, derived from the deck slot. Zero until
    /// the first layout pass, which is why prefetching also keys off it.
    @State private var cardTargetSize: CGSize = .zero
    /// What is currently warm, and at what size, so leaving cards can be
    /// released precisely (the cache keys on size).
    @State private var prefetched: [PhotoAsset] = []
    @State private var prefetchedSize: CGSize = .zero

    /// Fires once the deck finishes its first load. The Clean tab passes this so
    /// RootView's launch splash can wait for real content before crossfading in;
    /// every other entry point leaves it as the no-op default.
    private let onLoaded: () -> Void
    /// Passed to the end-of-deck screen. Nil for pushed decks (they pop);
    /// the Clean tab supplies a tab switch since it can't be dismissed.
    private let onBackToBrowse: (() -> Void)?

    /// What we actually offset the card by. During the drag we follow the
    /// gesture; while flinging the card off-screen we switch to the explicit
    /// exit offset so the GestureState reset doesn't snap us back to center.
    private var displayOffset: CGSize {
        isExiting ? exitOffset : dragTranslation
    }

    init(service: PhotoLibraryService,
         store: ReviewStore,
         stats: StatsStore,
         sizes: SizeStore,
         source: DeckSource,
         onLoaded: @escaping () -> Void = {},
         onBackToBrowse: (() -> Void)? = nil) {
        self.service = service
        self.store = store
        self.stats = stats
        self.sizes = sizes
        self.onLoaded = onLoaded
        self.onBackToBrowse = onBackToBrowse
        self._viewModel = StateObject(
            wrappedValue: SwipeViewModel(store: store, stats: stats, sizes: sizes, source: source)
        )
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
                // The reader measures the deck slot so the prefetcher can ask
                // PhotoKit for exactly the size the card itself will request.
                GeometryReader { proxy in
                    Group {
                        if viewModel.isLoading {
                            if viewModel.isMeasuring {
                                measuringState
                            } else {
                                ProgressView("Loading library…")
                                    .controlSize(.large)
                            }
                        } else if let asset = viewModel.currentAsset {
                            card(for: asset)
                        } else {
                            CaughtUpView(totalReviewed: store.reviewedIDs.count,
                                         onBackToBrowse: onBackToBrowse)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onChange(of: proxy.size, initial: true) { _, size in
                        cardTargetSize = DeckCardMetrics.pixelSize(forSlot: size)
                    }
                }

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
            await viewModel.loadIfNeeded(using: service)
            onLoaded()
            prefetchUpcoming()
        }
        .onChange(of: service.libraryVersion) { _, _ in
            Task {
                await viewModel.refreshIfStale(using: service)
                prefetchUpcoming()
            }
        }
        .onChange(of: viewModel.currentIndex) { _, _ in prefetchUpcoming() }
        .onChange(of: cardTargetSize) { _, _ in prefetchUpcoming() }
        .onDisappear { releasePrefetched() }
        .onChange(of: viewModel.lastFreedBytes) { _, newValue in
            scheduleFreedBannerDismiss(for: newValue)
        }
        .sheet(isPresented: $showReviewSheet) {
            DeleteReviewSheet(
                service: service,
                store: store,
                onConfirm: { await viewModel.confirmDelete(using: service) }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $zoomAsset) { asset in
            PhotoZoomView(asset: asset, service: service)
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

    // MARK: - Prefetch

    /// Keeps the next few cards' images warm. Cards that left the window are
    /// released, so the cache stays a fixed size regardless of deck length.
    /// A size change (rotation, first layout) re-warms the whole window at
    /// the new size, since the old entries are keyed on the old one.
    private func prefetchUpcoming() {
        let upcoming = viewModel.upcomingAssets(limit: prefetchDepth)
        if prefetchedSize != cardTargetSize {
            service.stopCaching(prefetched, targetSize: prefetchedSize)
            service.startCaching(upcoming, targetSize: cardTargetSize)
        } else {
            let upcomingIDs = Set(upcoming.map(\.id))
            let prefetchedIDs = Set(prefetched.map(\.id))
            service.stopCaching(prefetched.filter { !upcomingIDs.contains($0.id) },
                                targetSize: prefetchedSize)
            service.startCaching(upcoming.filter { !prefetchedIDs.contains($0.id) },
                                 targetSize: cardTargetSize)
        }
        prefetched = upcoming
        prefetchedSize = cardTargetSize
    }

    /// Drops the warm window when the deck leaves the screen. Re-appearing
    /// re-runs `.task`, which warms it again.
    private func releasePrefetched() {
        service.stopCaching(prefetched, targetSize: prefetchedSize)
        prefetched = []
    }

    // MARK: - Measuring (largest-first first open)

    /// Determinate progress while file sizes are read for a largest-first
    /// deck. Cancel stops the measurement and pops the deck, since the order
    /// can't be built without the sizes; what was measured is kept for next
    /// time only once the run completes.
    private var measuringState: some View {
        VStack(spacing: 20) {
            ProgressView(value: Double(viewModel.measuredCount),
                         total: Double(max(1, viewModel.measureTotal))) {
                Text("Measuring file sizes…")
            } currentValueLabel: {
                Text("\(viewModel.measuredCount) of \(viewModel.measureTotal)")
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            Text("Only once — sizes are remembered for next time.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Cancel") {
                viewModel.cancelMeasuring()
                dismiss()
            }
        }
    }

    // MARK: - Card

    private func card(for asset: PhotoAsset) -> some View {
        deckCard(for: asset)
            .overlay(alignment: .top) { cardStamps }
            .overlay { upStamp }
            .overlay(alignment: .bottom) {
                if asset.id == viewModel.source.suggestedKeeperID {
                    keeperBadge
                }
            }
            .padding(.horizontal, DeckCardMetrics.horizontalInset)
            .padding(.vertical, DeckCardMetrics.verticalInset)
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
            // Two-finger pinch opens the fullscreen inspector (photos only —
            // a video card taps to play/pause instead). Distinct from the
            // one-finger drag, so both can coexist via simultaneous.
            .simultaneousGesture(
                MagnificationGesture()
                    .onEnded { finalScale in
                        if !asset.isVideo, finalScale > 1.15 {
                            zoomAsset = asset
                        }
                    }
            )
            .accessibilityHint("Swipe right to keep, swipe left to mark for deletion, swipe up to \(swipeUpAction.title.lowercased())")
            .accessibilityAction(named: Text("Keep")) {
                viewModel.keep()
            }
            .accessibilityAction(named: Text("Mark for deletion")) {
                viewModel.markForDeletion()
            }
            .accessibilityAction(named: Text(swipeUpAction.title)) {
                viewModel.swipeUp(action: swipeUpAction, using: service)
            }
            // Identity tied to the asset so SwiftUI rebuilds (and the card's
            // .task reloads) when the deck advances.
            .id(asset.id)
    }

    /// Picks the right card renderer for the asset. Both share the swipe /
    /// stamp / tint mechanics above — only the content differs.
    @ViewBuilder
    private func deckCard(for asset: PhotoAsset) -> some View {
        if asset.isVideo {
            VideoCardView(asset: asset, service: service)
        } else {
            CardView(asset: asset, service: service)
        }
    }

    /// Marks the highest-quality shot in a duplicate group as the one to keep.
    private var keeperBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
            Text("Suggested keeper")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 40)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Stamps that fade in with the swipe — Tinder-style direction cue.
    /// Decorative; the underlying card carries the a11y label.
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
        .accessibilityHidden(true)
    }

    /// Centre stamp for the vertical swipe (Favorite / album), fading in with
    /// the upward drag the same way the side stamps follow the horizontal one.
    private var upStamp: some View {
        stamp(text: swipeUpAction.title, systemImage: swipeUpAction.systemImage, color: .yellow)
            .opacity(Double(upProgress))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        let up = upProgress
        let tint: Color = up > abs(progress) ? .yellow : (progress > 0 ? .green : .red)
        return tint.opacity(Double(max(up, abs(progress))) * 0.18)
    }

    /// Horizontal progress toward a commit, −1…1. Suppressed while the drag is
    /// clearly vertical so the side stamps don't flicker during a swipe-up.
    private var swipeProgress: CGFloat {
        guard swipeThreshold > 0, !isVerticalDrag else { return 0 }
        return max(-1, min(1, displayOffset.width / swipeThreshold))
    }

    /// Upward progress toward a commit, 0…1. Only while the drag is vertical.
    private var upProgress: CGFloat {
        guard swipeThreshold > 0, isVerticalDrag else { return 0 }
        return max(0, min(1, -displayOffset.height / swipeThreshold))
    }

    /// The drag's dominant axis decides which gesture this is.
    private var isVerticalDrag: Bool {
        displayOffset.height < 0 && abs(displayOffset.height) > abs(displayOffset.width)
    }

    // MARK: - Gesture handling

    private func handleDragEnd(translation: CGSize) {
        // A second flick that lands while the previous card is still flying
        // off would schedule a second decision, which then applies to the next
        // card before the user has seen it. Ignore it until the swap completes.
        guard !isExiting else { return }
        let vertical = translation.height < 0
            && abs(translation.height) > abs(translation.width)
        let committed = vertical
            ? -translation.height > swipeThreshold
            : abs(translation.width) > swipeThreshold
        guard committed else {
            // GestureState resets automatically; the .animation modifier
            // springs the card back to centre.
            return
        }
        completeSwipe(translation: translation, vertical: vertical)
    }

    private enum SwipeDirection { case left, right, up }

    private func completeSwipe(translation: CGSize, vertical: Bool) {
        let direction: SwipeDirection = vertical ? .up : (translation.width > 0 ? .right : .left)
        let exit: CGSize
        switch direction {
        case .right: exit = CGSize(width: exitDistance, height: translation.height)
        case .left:  exit = CGSize(width: -exitDistance, height: translation.height)
        case .up:    exit = CGSize(width: translation.width, height: -exitDistance)
        }

        // Anchor exitOffset to the lift-off point so swapping the displayOffset
        // source (dragTranslation → exitOffset) doesn't snap the card.
        exitOffset = translation
        isExiting = true
        withAnimation(.easeOut(duration: 0.25)) {
            exitOffset = exit
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            // Batched state changes: VM advances and source flips back to
            // dragTranslation (0) in the same render cycle, so the next card
            // mounts centred — never visible at the exit position.
            switch direction {
            case .right: viewModel.keep()
            case .left:  viewModel.markForDeletion()
            case .up:    viewModel.swipeUp(action: swipeUpAction, using: service)
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
                viewModel.undo(using: service)
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
