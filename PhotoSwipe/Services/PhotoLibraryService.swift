import Photos
import SwiftUI

/// Owns photo-library authorization. Fetch, image loading, and batch delete
/// are added in later milestones.
@MainActor
final class PhotoLibraryService: ObservableObject {

    /// App-level access state. We only proceed with the swipe flow on full
    /// access — `.limited` can't support bulk cleaning, so it is treated as
    /// blocked alongside `.denied`/`.restricted`.
    enum AccessState: Equatable {
        case undetermined
        case authorized   // full read/write access
        case blocked      // limited, denied, or restricted
    }

    @Published private(set) var accessState: AccessState

    init() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        accessState = Self.map(status)
    }

    /// Prompts for full access if undetermined. On already-resolved statuses
    /// this just refreshes our cached state.
    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        accessState = Self.map(status)
    }

    /// Re-reads the current status — call when returning from Settings.
    func refreshAccessState() {
        accessState = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> AccessState {
        switch status {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .undetermined
        case .limited, .denied, .restricted:
            return .blocked
        @unknown default:
            return .blocked
        }
    }
}
