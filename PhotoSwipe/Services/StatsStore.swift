import Foundation
import SwiftUI

/// Persists cumulative freed-space and a chronological log of successful
/// batch deletes. Local-only, UserDefaults-backed to match ReviewStore. Both
/// numbers are surfaced through the Activity Log screen; the per-batch toast
/// still lives on SwipeViewModel.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var totalBytesFreed: Int64
    /// Most-recent-first ordering so the log view can render without resorting.
    @Published private(set) var history: [DeleteRecord]

    /// Called after a successful persist so `AppStores` can republish the
    /// App Group summary. Deliberately not `@Published`.
    var onPersist: (() -> Void)?

    private let defaults: UserDefaults
    private let bytesKey = "PhotoSwipe.stats.totalBytesFreed"
    private let historyKey = "PhotoSwipe.stats.deleteHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Int and Int64 are the same width on iOS — this round-trip is lossless.
        self.totalBytesFreed = Int64(defaults.integer(forKey: bytesKey))
        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([DeleteRecord].self, from: data) {
            self.history = decoded
        } else {
            self.history = []
        }
    }

    var totalPhotosDeleted: Int {
        history.reduce(0) { $0 + $1.count }
    }

    /// Bytes reclaimed in the calendar month containing `date`. Derived from
    /// the delete log rather than a separate counter, so it stays correct
    /// across month rollovers without anything having to reset it.
    func bytesFreed(inMonthOf date: Date) -> Int64 {
        let month = CleanupSummary.monthKey(date)
        return history
            .filter { CleanupSummary.monthKey($0.date) == month }
            .reduce(0) { $0 + $1.bytesFreed }
    }

    /// Record a successful batch delete. Called by SwipeViewModel after
    /// PhotoKit confirms deletion, so `count`/`bytesFreed` reflect real work.
    func recordDelete(count: Int, bytesFreed: Int64) {
        let record = DeleteRecord(count: count, bytesFreed: bytesFreed)
        history.insert(record, at: 0)
        totalBytesFreed += bytesFreed
        persist()
    }

    private func persist() {
        defaults.set(Int(totalBytesFreed), forKey: bytesKey)
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
        onPersist?()
    }
}
