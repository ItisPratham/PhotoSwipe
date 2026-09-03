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

    @AppStorage(SwipeUpAction.kindKey) private var swipeUpKind = "favorite"
    @AppStorage(SwipeUpAction.albumIDKey) private var swipeUpAlbumID = ""
    @AppStorage(SwipeUpAction.albumTitleKey) private var swipeUpAlbumTitle = ""

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
                    Picker(selection: $swipeUpKind) {
                        Label("Favorite", systemImage: "heart.fill").tag("favorite")
                        Label("Add to album", systemImage: "rectangle.stack.badge.plus").tag("album")
                    } label: {
                        Label("Swipe up does", systemImage: "arrow.up")
                    }
                    if swipeUpKind == "album" {
                        NavigationLink {
                            SwipeUpAlbumPicker(service: service,
                                               selectedID: $swipeUpAlbumID,
                                               selectedTitle: $swipeUpAlbumTitle)
                        } label: {
                            LabeledContent("Album") {
                                Text(swipeUpAlbumTitle.isEmpty ? "Choose…" : swipeUpAlbumTitle)
                                    .foregroundStyle(swipeUpAlbumTitle.isEmpty ? .secondary : .primary)
                            }
                        }
                    }
                } footer: {
                    Text(swipeUpKind == "album" && swipeUpAlbumTitle.isEmpty
                         ? "Swiping up keeps the photo. Pick an album to also add it there; until then it favorites."
                         : "Swiping up keeps the photo and \(swipeUpKind == "album" ? "adds it to the album" : "marks it as a favorite in Photos"). Undo reverts both.")
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
                Text("Everything you've kept or marked comes back into the deck. This only clears PhotoSwipe's own tracking; your Photos library isn't touched.")
            }
        }
    }

    private func openSupport() {
        guard let url = ContactLink.makeSupportURL() else { return }
        openURL(url)
    }
}

/// Lists the user's writable albums so swipe-up can add to one. Picking a
/// row stores the album's id and title; the deck reads both.
private struct SwipeUpAlbumPicker: View {
    let service: PhotoLibraryService
    @Binding var selectedID: String
    @Binding var selectedTitle: String

    @State private var albums: [PhotoLibraryService.AlbumSummary] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView("No albums",
                                       systemImage: "rectangle.stack",
                                       description: Text("Create an album in the Photos app first."))
            } else {
                List(albums) { album in
                    Button {
                        selectedID = album.id
                        selectedTitle = album.title
                        dismiss()
                    } label: {
                        HStack {
                            Text(album.title).foregroundStyle(.primary)
                            Spacer()
                            if album.id == selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Swipe-up album")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = await service.fetchWritableAlbums()
            isLoading = false
        }
    }
}

#Preview {
    SettingsView(service: PhotoLibraryService(), store: ReviewStore(), stats: StatsStore())
}
