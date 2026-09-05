import SwiftUI
import UIKit

/// Routes between the first-run onboarding, the permission flow, and the
/// swipe flow. Onboarding is shown once — the seen-flag lives in
/// UserDefaults via @AppStorage so a reinstall re-shows the tutorial.
struct RootView: View {
    @StateObject private var library = PhotoLibraryService()
    /// The decision, stats, and size stores, owned here but never read here.
    /// Held in one plain object under `@State` rather than as `@StateObject`s
    /// so their changes (every swipe) don't re-render the root shell and,
    /// through it, the whole tab tree.
    @State private var stores = AppStores()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("PhotoSwipe.hasSeenOnboarding") private var hasSeenOnboarding = false

    /// Launch-splash gating. The splash stays up until the content beneath is
    /// ready *and* a minimum on-screen time has passed, then crossfades out.
    @State private var launchFinished = false
    @State private var minTimeElapsed = false
    @State private var homeLoaded = false
    /// The stale-decision prune runs once per launch, after the first deck is
    /// up, so it never competes with the launch fetch.
    @State private var hasPrunedDecisions = false
    /// A `photoswipe://` link captured on arrival but not acted on until
    /// onboarding, permission, and the splash are out of the way. Only the
    /// most recent one survives; it is cleared once the shell consumes it.
    @State private var pendingCleanRequest: CleanRequest?

    /// Only the authorized home path has a library fetch to wait on; onboarding
    /// and the permission screen have nothing to load.
    private var requiresLibraryLoad: Bool {
        hasSeenOnboarding && library.accessState == .authorized
    }

    private var contentReady: Bool {
        !requiresLibraryLoad || homeLoaded
    }

    private var readyToReveal: Bool {
        minTimeElapsed && contentReady
    }

    var body: some View {
        ZStack {
            content

            if !launchFinished {
                LaunchView(readyToReveal: readyToReveal) {
                    withAnimation(.easeOut(duration: 0.45)) {
                        launchFinished = true
                    }
                }
                .transition(.opacity)
            }
        }
        .task {
            // Floor on splash time so the deck always fans, settles, and swipes
            // in full even when the library loads instantly.
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            minTimeElapsed = true
        }
        .task {
            // First publish once the decisions are actually loaded, so the
            // widget picks up this install's real numbers.
            await stores.review.waitUntilLoaded()
            stores.publishSummary()
        }
        .onOpenURL { url in
            guard let request = CleanRequest(url: url) else { return }
            pendingCleanRequest = request
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-check after the user may have changed access in Settings,
                // and catch library changes made while we were suspended.
                library.refreshAccessState()
                library.checkForMissedChanges()
                // The calendar may have rolled over while we were away, which
                // ages the streak and the month total.
                if !stores.review.isPersisted { stores.review.flush() }
                stores.publishSummary()
            case .background:
                // Land any debounced decision write before we can be killed.
                // `flush` republishes the summary through the persist hook,
                // so the widget sees the session's final numbers.
                stores.review.flush()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasSeenOnboarding {
            OnboardingView {
                hasSeenOnboarding = true
            }
        } else {
            switch library.accessState {
            case .undetermined:
                PermissionView(isBlocked: false) {
                    await library.requestAuthorization()
                }
            case .blocked:
                PermissionView(isBlocked: true) {
                    await library.requestAuthorization()
                }
            case .authorized:
                AppTabView(library: library,
                           reviewStore: stores.review,
                           statsStore: stores.stats,
                           sizeStore: stores.sizes,
                           // Held back until the splash is gone, so a cold
                           // launch from a widget doesn't push behind it.
                           cleanRequest: launchFinished ? pendingCleanRequest : nil,
                           onCleanRequestHandled: { pendingCleanRequest = nil },
                           onCleanLoaded: {
                               homeLoaded = true
                               guard !hasPrunedDecisions else { return }
                               hasPrunedDecisions = true
                               Task { await stores.review.pruneMissing(using: library) }
                           })
            }
        }
    }

}

/// The app-wide stores that outlive every screen. Created once with the root
/// view; not observable itself, so holding it in `@State` doesn't subscribe
/// the root to the stores' changes. Screens that display store values still
/// observe the individual store they read.
///
/// It also owns the one place that turns both stores into the App Group
/// snapshot the widget and intents read. The stores call back here after they
/// persist; because those callbacks are plain closures rather than published
/// changes, a swipe still doesn't re-render the tab tree.
@MainActor
final class AppStores {
    let review = ReviewStore()
    let stats = StatsStore()
    let sizes = SizeStore()

    /// Monotonic, so the writer can drop a snapshot that lost a race.
    private var revision = 0

    init() {
        review.onPersist = { [weak self] in self?.publishSummary() }
        stats.onPersist = { [weak self] in self?.publishSummary() }
    }

    /// Reads both stores together and hands the writer one complete snapshot.
    /// A no-op until review decisions have finished loading — publishing an
    /// empty set would tell the widget the user had nothing marked.
    func publishSummary(now: Date = Date()) {
        guard review.isPersisted else { return }
        revision += 1
        let window = Set(CleanupSummary.recentDayKeys(endingAt: now))
        let summary = CleanupSummary(
            markedCount: review.markedForDeletionIDs.count,
            totalBytesFreed: stats.totalBytesFreed,
            totalPhotosDeleted: stats.totalPhotosDeleted,
            lastSessionDate: review.lastSessionDate,
            streakDays: review.streakDays(now: now),
            monthBytesFreed: stats.bytesFreed(inMonthOf: now),
            generatedAt: now,
            monthKey: CleanupSummary.monthKey(now),
            activeDayKeys: review.decisionsByDay.keys.filter(window.contains).sorted()
        )
        let revision = revision
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Publish cleanup summary") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            await SummaryWriter.shared.write(summary, revision: revision)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }
}

#Preview {
    RootView()
}
