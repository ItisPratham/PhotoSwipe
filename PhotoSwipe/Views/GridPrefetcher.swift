import Foundation
import SwiftUI

/// Keeps a window of grid thumbnails warm around what is on screen, so
/// scrolling lands on ready images instead of the thumbnail-then-full
/// transition. Cells report their flat index as they appear and disappear;
/// a short debounce folds a scroll's burst of reports into one recompute,
/// which warms `[lowest visible − behind, highest visible + ahead]` through
/// the service's caching manager at exactly the size the cells request and
/// releases whatever left the window.
///
/// Not observable on purpose: visibility bookkeeping must not re-render the
/// grid that is reporting it. Hold it in `@State`.
@MainActor
final class GridPrefetcher {
    private let targetSize: CGSize
    private let ahead: Int
    private let behind: Int

    private var service: PhotoLibraryService?
    private var assets: [PhotoAsset] = []
    private var visible = Set<Int>()
    private var warm: [PhotoAsset] = []
    private var pending: Task<Void, Never>?

    /// `targetSize` must match what the cells ask `imageStream` for; the
    /// cache keys on it. `ahead`/`behind` are in cells: 48 ahead is twelve
    /// rows of a four-column grid, about two screens.
    init(targetSize: CGSize, ahead: Int = 48, behind: Int = 16) {
        self.targetSize = targetSize
        self.ahead = ahead
        self.behind = behind
    }

    func attach(_ service: PhotoLibraryService) {
        self.service = service
    }

    /// The flat list the cells index into. Replacing it (a library refresh)
    /// releases the old window; the cells re-report as they re-appear.
    func update(assets: [PhotoAsset]) {
        release()
        self.assets = assets
    }

    func cellAppeared(_ index: Int) {
        visible.insert(index)
        schedule()
    }

    func cellDisappeared(_ index: Int) {
        visible.remove(index)
        schedule()
    }

    /// Drops the warm window (grid left the screen or its data changed).
    func release() {
        pending?.cancel()
        pending = nil
        service?.stopCaching(warm, targetSize: targetSize)
        warm = []
        visible.removeAll()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        guard let service, !assets.isEmpty,
              let low = visible.min(), let high = visible.max() else { return }
        let start = max(0, low - behind)
        let end = min(assets.count, high + ahead + 1)
        guard start < end else { return }
        let wanted = Array(assets[start..<end])

        let wantedIDs = Set(wanted.map(\.id))
        let warmIDs = Set(warm.map(\.id))
        service.stopCaching(warm.filter { !wantedIDs.contains($0.id) }, targetSize: targetSize)
        service.startCaching(wanted.filter { !warmIDs.contains($0.id) }, targetSize: targetSize)
        warm = wanted
    }
}
