import SwiftUI

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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-check after the user may have changed access in Settings,
                // and catch library changes made while we were suspended.
                library.refreshAccessState()
                library.checkForMissedChanges()
            case .background:
                // Land any debounced decision write before we can be killed.
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
@MainActor
final class AppStores {
    let review = ReviewStore()
    let stats = StatsStore()
    let sizes = SizeStore()
}

#Preview {
    RootView()
}
