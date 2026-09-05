import Foundation
import WidgetKit

/// Publishes `summary.json` into the App Group container and asks WidgetKit
/// to reload the widget afterwards.
///
/// Submissions are **complete snapshots** with a monotonically increasing
/// revision, taken together on the main actor. The actor drops anything older
/// than what it has already written, so two publishes racing (a debounced
/// review write landing behind a stats write, say) can never leave the file
/// holding a mix of old and new numbers. Encoding and the atomic replace run
/// here, off the main actor — a swipe never pays for them.
///
/// A failed write (or a missing App Group) leaves the previous valid file in
/// place and does *not* advance the revision, so the next persist or the next
/// foreground refresh retries.
actor SummaryWriter {
    static let shared = SummaryWriter()

    /// Nil when the App Group is not provisioned for this build. Injectable
    /// so tests can exercise the revision ordering against a real file.
    private let url: URL?
    private var lastWrittenRevision = 0
    /// Logged once; a missing container is a provisioning problem, not
    /// something a retry loop can fix.
    private var reportedMissingContainer = false

    init(url: URL? = CleanupSummary.fileURL) {
        self.url = url
    }

    func write(_ summary: CleanupSummary, revision: Int) {
        guard revision > lastWrittenRevision else { return }
        guard let url else {
            if !reportedMissingContainer {
                reportedMissingContainer = true
                print("[PhotoSwipe] App Group \(CleanupSummary.appGroupID) is unavailable; " +
                      "the widget and intents will show no data until it is provisioned.")
            }
            return
        }
        do {
            try JSONEncoder().encode(summary).write(to: url, options: .atomic)
            lastWrittenRevision = revision
            WidgetCenter.shared.reloadTimelines(ofKind: CleanupSummary.widgetKind)
        } catch {
            print("[PhotoSwipe] Failed to publish the widget summary: \(error)")
        }
    }
}
