import Foundation

/// The complete snapshot the app publishes into the App Group container for
/// its extensions. The widget and the read-only intents see **only** this
/// file: `review.json`, the SwiftData indexes, and UserDefaults all stay in
/// the app's private container, where an extension cannot reach them.
///
/// Every field the widget needs to render is in here, including the ones the
/// brief's six-field schema implies rather than states: `generatedAt` and
/// `monthKey` let a stale snapshot be recognised after a month rolls over
/// (the widget then shows zero for the current month instead of last month's
/// total), and `activeDayKeys` carries the seven-day strip so the extension
/// never has to reconstruct per-day history it cannot read.
struct CleanupSummary: Codable, Equatable {
    /// Photos currently queued for the next batch delete.
    var markedCount: Int
    /// Lifetime bytes reclaimed by successful deletes.
    var totalBytesFreed: Int64
    /// Lifetime count of photos actually removed from the library.
    var totalPhotosDeleted: Int
    /// When the user last decided something. Nil before the first swipe.
    var lastSessionDate: Date?
    /// Consecutive active days ending today or yesterday, at snapshot time.
    var streakDays: Int
    /// Bytes reclaimed inside `monthKey`.
    var monthBytesFreed: Int64
    var generatedAt: Date
    /// `yyyy-MM` of `generatedAt`, so a reader can detect a month rollover.
    var monthKey: String
    /// `yyyy-MM-dd` keys with at least one decision, within the seven days
    /// ending at `generatedAt`.
    var activeDayKeys: [String]

    /// Shared with the widget target and both read-only intents.
    static let appGroupID = "group.com.phototinder.PhotoSwipe"
    /// The single widget kind, used for targeted timeline reloads.
    static let widgetKind = "PhotoSwipeSummary"

    /// The month total as of `date`: zero once the snapshot belongs to an
    /// earlier month, because last month's progress is not this month's. Lives
    /// here rather than in the widget so the rollover rule is testable.
    func bytesFreed(inMonthOf date: Date) -> Int64 {
        monthKey == Self.monthKey(date) ? monthBytesFreed : 0
    }

    /// The streak as of `date`. A streak may end today or yesterday, so a
    /// snapshot still describes the day after it was taken; beyond that the
    /// app has not reported activity we cannot see, and the honest answer is
    /// zero rather than a number frozen at the last publish.
    func streakDays(on date: Date, calendar: Calendar = .localGregorian) -> Int {
        let taken = calendar.startOfDay(for: generatedAt)
        let shown = calendar.startOfDay(for: date)
        let elapsed = calendar.dateComponents([.day], from: taken, to: shown).day ?? 0
        return elapsed <= 1 ? streakDays : 0
    }

    /// Nil when the App Group is not provisioned for this build — an explicit
    /// integration error rather than a silent fallback to a private file that
    /// extensions could never read anyway.
    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "summary.json")
    }

    /// The published snapshot, or nil when it is missing or corrupt. Callers
    /// show "open the app once" rather than inventing zero totals.
    static func read() -> CleanupSummary? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Local-calendar day identity, shared by the review store (which counts
    /// decisions per day) and the widget (which renders the strip). One
    /// implementation so the two can never disagree about where a day ends.
    static func dayKey(_ date: Date, calendar: Calendar = .localGregorian) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func monthKey(_ date: Date, calendar: Calendar = .localGregorian) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The seven day keys ending at `date`, oldest first — the widget strip's
    /// x-axis, and the window `activeDayKeys` is filtered to.
    static func recentDayKeys(endingAt date: Date, calendar: Calendar = .localGregorian) -> [String] {
        let today = calendar.startOfDay(for: date)
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey($0, calendar: calendar) }
        }
    }
}

extension Calendar {
    /// Gregorian in the device's current time zone. Day keys are local, so a
    /// swipe at 23:59 belongs to the day the user just spent, not to UTC's.
    static var localGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
