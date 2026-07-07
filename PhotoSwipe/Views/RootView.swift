import SwiftUI

/// Routes between the first-run onboarding, the permission flow, and the
/// swipe flow. Onboarding is shown once — the seen-flag lives in
/// UserDefaults via @AppStorage so a reinstall re-shows the tutorial.
struct RootView: View {
    @StateObject private var library = PhotoLibraryService()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var statsStore = StatsStore()
    @StateObject private var sizeStore = SizeStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("PhotoSwipe.hasSeenOnboarding") private var hasSeenOnboarding = false

    /// Launch-splash gating. The splash stays up until the content beneath is
    /// ready *and* a minimum on-screen time has passed, then crossfades out.
    @State private var launchFinished = false
    @State private var minTimeElapsed = false
    @State private var browseLoaded = false

    /// Only the Browse path has a library fetch to wait on; onboarding and the
    /// permission screen have nothing to load.
    private var requiresLibraryLoad: Bool {
        hasSeenOnboarding && library.accessState == .authorized
    }

    private var contentReady: Bool {
        !requiresLibraryLoad || browseLoaded
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
            // Re-check after the user may have changed access in Settings.
            if phase == .active {
                library.refreshAccessState()
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
                NavigationStack {
                    BrowseView(service: library,
                               store: reviewStore,
                               stats: statsStore,
                               onLoaded: { browseLoaded = true })
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .albums:
                                AlbumListView(service: library)
                            case .duplicates:
                                DuplicatesView(service: library)
                            case .swipe(let source):
                                SwipeView(service: library,
                                          store: reviewStore,
                                          stats: statsStore,
                                          sizes: sizeStore,
                                          source: source)
                            }
                        }
                }
            }
        }
    }

}

#Preview {
    RootView()
}
