import SwiftUI

/// Routes between the permission flow and the swipe flow based on photo-library
/// access. The swipe UI itself lands in a later milestone.
struct RootView: View {
    @StateObject private var library = PhotoLibraryService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
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
                SwipeView(service: library)
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
