import SwiftUI

/// Shown when access is undetermined (to request) or blocked (limited/denied).
/// Bulk cleaning needs full access, so limited access is treated as blocked
/// and the user is deep-linked to Settings.
struct PermissionView: View {
    let isBlocked: Bool
    let onRequest: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Full photo access needed")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button(action: primaryAction) {
                Text(isBlocked ? "Open Settings" : "Allow Photo Access")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private var explanation: String {
        if isBlocked {
            return "PhotoSwipe needs full access to your library to let you swipe through and delete photos. Please enable Full Access in Settings."
        }
        return "PhotoSwipe lets you swipe through your library to clear out photos you no longer want. Grant full access to get started — your photos never leave your device."
    }

    private func primaryAction() {
        if isBlocked {
            openSettings()
        } else {
            Task { await onRequest() }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview("Undetermined") {
    PermissionView(isBlocked: false, onRequest: {})
}

#Preview("Blocked") {
    PermissionView(isBlocked: true, onRequest: {})
}
