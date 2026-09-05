import AppIntents
import UIKit

/// Siri and Shortcuts entry points.
///
/// The two read-only intents answer from `summary.json` alone — they never
/// touch PhotoKit, the indexes, or the review file, so asking how much space
/// you have freed never spins up the library. That works because the stores
/// are created by `RootView`, which only exists once a scene connects.
///
/// `StartCleaningIntent` is the only one that opens the UI. It foregrounds the
/// app and then opens the same canonical `photoswipe://` URL the widget uses,
/// so there is one routing path rather than an intent-specific one. (iOS 18's
/// `OpenURLIntent` would do this declaratively; this release targets 17.0.)
struct StartCleaningIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Cleaning"
    static var description = IntentDescription("Opens PhotoSwipe on a deck of photos to review.")
    static var openAppWhenRun = true

    @Parameter(title: "Deck", description: "Which photos to clean. Leave empty for everything.")
    var entry: CleanEntry?

    @MainActor
    func perform() async throws -> some IntentResult {
        await UIApplication.shared.open(CleanRequest(entry: entry).url)
        return .result()
    }
}

struct SpaceFreedIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Space Freed"
    static var description = IntentDescription("Reports how much space PhotoSwipe has reclaimed.")
    /// Read-only: answers without showing the app.
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let summary = try CleanupSummary.published()
        let freed = ByteCountFormatter.string(fromByteCount: summary.totalBytesFreed,
                                              countStyle: .file)
        let dialog: IntentDialog = summary.totalPhotosDeleted == 0
            ? "You haven't deleted any photos yet."
            : "You've freed \(freed) by deleting \(summary.totalPhotosDeleted) photos."
        return .result(value: freed, dialog: dialog)
    }
}

struct MarkedCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Marked Photos"
    static var description = IntentDescription("Reports how many photos are waiting to be deleted.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let count = try CleanupSummary.published().markedCount
        let dialog: IntentDialog = switch count {
        case 0: "Nothing is marked for deletion."
        case 1: "1 photo is marked for deletion."
        default: "\(count) photos are marked for deletion."
        }
        return .result(value: count, dialog: dialog)
    }
}

extension CleanupSummary {
    /// The published snapshot, or an error telling the user what to do. Never
    /// a zeroed placeholder: "nothing freed" and "I can't see yet" are
    /// different answers.
    static func published() throws -> CleanupSummary {
        guard let summary = read() else { throw IntentSummaryError.unavailable }
        return summary
    }
}

enum IntentSummaryError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        "Open PhotoSwipe once so it can share your cleanup summary."
    }
}

/// The deep-link entries, offered as a Shortcuts parameter. The conformance
/// lives here rather than on the type so the widget, which compiles the same
/// file, doesn't pull AppIntents in with it.
extension CleanEntry: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Deck" }

    static var caseDisplayRepresentations: [CleanEntry: DisplayRepresentation] {
        [.screenshots: "Screenshots", .biggest: "Biggest files", .duplicates: "Duplicates"]
    }
}

struct PhotoSwipeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCleaningIntent(),
            phrases: ["Start cleaning in \(.applicationName)",
                      "Clean up my photos with \(.applicationName)",
                      "Open \(.applicationName) and start swiping"],
            shortTitle: "Start cleaning",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: SpaceFreedIntent(),
            phrases: ["How much space have I freed with \(.applicationName)",
                      "Space freed in \(.applicationName)",
                      "Ask \(.applicationName) how much space I saved"],
            shortTitle: "Space freed",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: MarkedCountIntent(),
            phrases: ["How many photos are marked in \(.applicationName)",
                      "Marked photos in \(.applicationName)",
                      "Ask \(.applicationName) what's waiting to be deleted"],
            shortTitle: "Marked photos",
            systemImageName: "trash"
        )
    }
}
