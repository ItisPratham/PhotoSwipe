import SwiftUI

/// Routes between the first-run onboarding, the permission flow, and the
/// swipe flow. Onboarding is shown once — the seen-flag lives in
/// UserDefaults via @AppStorage so a reinstall re-shows the tutorial.
struct RootView: View {
    @StateObject private var library = PhotoLibraryService()
    @StateObject private var reviewStore = ReviewStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("PhotoSwipe.hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        Group {
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
                        SwipeView(service: library, store: reviewStore)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            // Re-check after the user may have changed access in Settings.
            if phase == .active {
                library.refreshAccessState()
            }
        }
    }

}

#Preview {
    RootView()
}
