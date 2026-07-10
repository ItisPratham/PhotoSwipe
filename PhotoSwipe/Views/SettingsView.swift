import SwiftUI

/// The settings gear, presented as a sheet from every tab's toolbar. Hosts the
/// utilities that used to live in Browse's overflow menu: the activity log, a
/// tutorial replay, support contact, and the destructive review-history reset.
struct SettingsView: View {
    @ObservedObject var store: ReviewStore
    @ObservedObject var stats: StatsStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showTutorial = false
    @State private var showStats = false
    @State private var showResetConfirm = false

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
        }
    }

    private func openSupport() {
        guard let url = ContactLink.makeSupportURL() else { return }
        openURL(url)
    }
}

#Preview {
    SettingsView(store: ReviewStore(), stats: StatsStore())
}
