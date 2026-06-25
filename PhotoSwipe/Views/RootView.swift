import SwiftUI

/// Placeholder root. Routing between permission / swipe / caught-up states
/// is wired up in a later milestone.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("PhotoSwipe")
                .font(.largeTitle.bold())
            Text("Scaffold ready.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
