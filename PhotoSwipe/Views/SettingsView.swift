import SwiftUI

/// The settings gear, presented as a sheet from every tab's toolbar. Hosts the
/// utilities that used to live in Browse's overflow menu: the activity log, a
/// tutorial replay, support contact, and the destructive review-history reset.
struct SettingsView: View {
    let service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    @ObservedObject var stats: StatsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showTutorial = false
    @State private var showStats = false
    @State private var showResetConfirm = false
    @State private var faceDataWiped = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showStats = true
                    } label: {
                        Label("Activity", systemImage: "chart.bar")
                    }
                }

                Section {
                    Button {
                        showTutorial = true
                    } label: {
                        Label("Show tutorial", systemImage: "questionmark.circle")
                    }
                    Button(action: openSupport) {
                        Label("Contact support", systemImage: "envelope")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Reset review history", systemImage: "arrow.counterclockwise")
                    }
                }

                Section {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "c.circle")
                    }
                }

                Section("Developer") {
                    NavigationLink {
                        FaceDebugView(service: service)
                    } label: {
                        Label("Face grouping debug", systemImage: "face.dashed")
                    }
                    Button {
                        Task {
                            try? await FaceStore(modelContainer: FaceContainer.shared).wipeAll()
                            faceDataWiped = true
                        }
                    } label: {
                        Label("Reset face data", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showTutorial) {
                OnboardingView { showTutorial = false }
            }
            .sheet(isPresented: $showStats) {
                StatsView(stats: stats)
            }
            .alert("Reset review history?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive, action: store.resetAll)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All photos you've kept or marked for deletion will re-enter the deck. Your Photos library isn't touched — this only clears PhotoSwipe's tracking.")
            }
            .alert("Face data reset", isPresented: $faceDataWiped) {
            } message: {
                Text("Open the People tab and scan to rebuild the face index from scratch.")
            }
        }
    }

    private func openSupport() {
        guard let url = ContactLink.makeSupportURL() else { return }
        openURL(url)
    }
}

#Preview {
    SettingsView(service: PhotoLibraryService(), store: ReviewStore(), stats: StatsStore())
}
