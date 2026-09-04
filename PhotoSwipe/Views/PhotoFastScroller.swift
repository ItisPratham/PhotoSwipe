import SwiftUI

/// A compact, direct-manipulation alternative to the system scroll indicator.
/// The visible rail is deliberately slim, while its transparent 44-point hit
/// area remains accessible when it is overlaid on a photo grid.
struct PhotoFastScroller: View {
    let itemCount: Int
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @State private var dragIndex: Int?
    @State private var pendingIndex: Int?
    @State private var dispatchTask: Task<Void, Never>?

    private let thumbHeight: CGFloat = 44
    /// Coalesce rapid drag updates. Sending a programmatic scroll for every
    /// touch sample can make a lazy photo grid create and cancel many image
    /// requests in a single frame.
    private let scrollInterval = Duration.milliseconds(120)

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, thumbHeight)
            let selected = clamped(dragIndex ?? currentIndex)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.tertiary.opacity(0.35))
                    .frame(width: 2)

                Capsule()
                    .fill(.secondary)
                    .frame(width: 5, height: thumbHeight)
                    .offset(y: thumbOffset(for: selected, height: height))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        select(at: value.location.y, height: height)
                    }
                    .onEnded { _ in finishDrag() }
            )
        }
        .frame(width: 44)
        .onDisappear(perform: cancelDispatch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fast scroll")
        .accessibilityValue("Item \(clamped(currentIndex) + 1) of \(itemCount)")
        .accessibilityHint("Swipe up or down to move quickly through the collection")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSelect(clamped(currentIndex + 1))
            case .decrement:
                onSelect(clamped(currentIndex - 1))
            @unknown default:
                break
            }
        }
    }

    private func select(at y: CGFloat, height: CGFloat) {
        guard itemCount > 1 else { return }
        let available = max(1, height - thumbHeight)
        let progress = min(max(0, y - thumbHeight / 2), available) / available
        let index = Int((progress * CGFloat(itemCount - 1)).rounded())
        guard index != dragIndex else { return }
        dragIndex = index
        enqueue(index)
    }

    private func finishDrag() {
        guard let dragIndex else { return }
        enqueue(dragIndex)
        self.dragIndex = nil
    }

    /// At most one grid jump is dispatched per interval. The newest pending
    /// index wins, and the final drag position is always retained.
    private func enqueue(_ index: Int) {
        pendingIndex = index
        guard dispatchTask == nil else { return }

        dispatchTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let next = pendingIndex else { break }
                pendingIndex = nil
                onSelect(next)

                do {
                    try await Task.sleep(for: scrollInterval)
                } catch {
                    break
                }
            }
            dispatchTask = nil
        }
    }

    private func cancelDispatch() {
        dispatchTask?.cancel()
        dispatchTask = nil
        pendingIndex = nil
    }

    private func thumbOffset(for index: Int, height: CGFloat) -> CGFloat {
        guard itemCount > 1 else { return 0 }
        return (height - thumbHeight) * CGFloat(index) / CGFloat(itemCount - 1)
    }

    private func clamped(_ index: Int) -> Int {
        min(max(0, index), max(0, itemCount - 1))
    }
}
