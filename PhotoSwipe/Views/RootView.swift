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
                authorizedPlaceholder
            }
        }
        .onChange(of: scenePhase) { phase in
            // Re-check after the user may have changed access in Settings.
            if phase == .active {
                library.refreshAccessState()
            }
        }
    }

    private var authorizedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Access granted")
                .font(.title2.bold())
            Text("Swipe flow coming in the next milestone.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
