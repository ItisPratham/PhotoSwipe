import SwiftUI

/// Placeholder for the People tab. On-device face clustering (detect → embed →
/// cluster) lands in v4.1; until then this shows a "coming soon" state so the
/// tab is present in the shell and the navigation shape is settled.
struct PeopleView: View {
    var body: some View {
        ContentUnavailableView {
            Label("People", systemImage: "person.2")
        } description: {
            Text("On-device face grouping is coming soon. You'll be able to scan your library and review photos by person — entirely on your device.")
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PeopleView()
    }
}
