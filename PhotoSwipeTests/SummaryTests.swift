import XCTest
@testable import PhotoSwipe

/// The activity history behind the streak, and the snapshot the widget and
/// intents read. Both are calendar-sensitive and both are written from paths
/// that can race, so the boundaries are pinned here rather than on a device.
final class SummaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Day keys

    func testDayKeyUsesTheLocalCalendarNotUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        // 2026-03-01 11:30 UTC is already the 2nd in Auckland: the day the
        // user spent is the local one.
        let instant = Date(timeIntervalSince1970: 1_772_364_600)
        XCTAssertEqual(CleanupSummary.dayKey(instant, calendar: calendar), "2026-03-02")
    }

    func testRecentDayKeysSpanSevenDaysAcrossADSTChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // US DST began 2026-03-08; a 23-hour day must not drop or duplicate.
        let keys = CleanupSummary.recentDayKeys(endingAt: date("2026-03-10", in: calendar),
                                                calendar: calendar)
        XCTAssertEqual(keys, ["2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07",
                              "2026-03-08", "2026-03-09", "2026-03-10"])
    }

    func testMonthKeyRollsOverWithTheCalendar() {
        let calendar = Calendar.localGregorian
        XCTAssertEqual(CleanupSummary.monthKey(date("2026-01-31", in: calendar)), "2026-01")
        XCTAssertEqual(CleanupSummary.monthKey(date("2026-02-01", in: calendar)), "2026-02")
    }

    // MARK: - Streaks

    func testStreakCountsBackFromToday() async {
        let store = await loadedStore(days: ["2026-09-05": 3, "2026-09-04": 1, "2026-09-03": 2])
        let streak = await store.streakDays(now: today("2026-09-05"))
        XCTAssertEqual(streak, 3)
    }

    func testStreakSurvivesAnUnswipedToday() async {
        let store = await loadedStore(days: ["2026-09-04": 1, "2026-09-03": 1])
        let streak = await store.streakDays(now: today("2026-09-05"))
        XCTAssertEqual(streak, 2, "A streak may still end yesterday.")
    }

    func testStreakIsZeroOnceTheLastActiveDayIsOlderThanYesterday() async {
        let store = await loadedStore(days: ["2026-09-03": 9, "2026-09-02": 9])
        let streak = await store.streakDays(now: today("2026-09-05"))
        XCTAssertEqual(streak, 0)
    }

    func testStreakStopsAtTheFirstGap() async {
        let store = await loadedStore(days: ["2026-09-05": 1, "2026-09-04": 1, "2026-09-02": 1])
        let streak = await store.streakDays(now: today("2026-09-05"))
        XCTAssertEqual(streak, 2)
    }

    func testResetKeepsActivityHistory() async {
        let store = await loadedStore(days: ["2026-09-05": 4])
        await store.resetAll()
        let reviewed = await store.reviewedIDs
        let streak = await store.streakDays(now: today("2026-09-05"))
        XCTAssertTrue(reviewed.isEmpty)
        XCTAssertEqual(streak, 1, "Clearing decisions must not erase the days worked.")
    }

    func testActivityRecordedTodaySurvivesUndo() async {
        let store = await loadedStore(days: [:])
        await store.markForDeletion("asset-1")
        await store.clearDecision(for: "asset-1")
        let streak = await store.streakDays()
        let marked = await store.markedForDeletionIDs
        XCTAssertEqual(streak, 1)
        XCTAssertTrue(marked.isEmpty)
    }

    func testActivityHistoryIsCappedAtTheOldestDays() async {
        // 400 consecutive days ending well before "today": one more decision
        // must evict the oldest, not the newest.
        let calendar = Calendar.localGregorian
        var days: [String: Int] = [:]
        for offset in 0..<400 {
            let day = calendar.date(byAdding: .day, value: -offset, to: date("2025-01-01"))!
            days[CleanupSummary.dayKey(day)] = 1
        }
        let oldest = days.keys.min()!
        let store = await loadedStore(days: days)
        await store.markKept("asset-1")
        let history = await store.decisionsByDay
        XCTAssertEqual(history.count, 400)
        XCTAssertNil(history[oldest])
        XCTAssertNotNil(history[CleanupSummary.dayKey(Date())])
    }

    func testOldReviewFilesWithoutActivityStillDecodeTheirDecisions() async {
        let url = directory.appending(path: "review.json")
        try? Data(#"{"reviewed":["a","b"],"marked":["b"]}"#.utf8).write(to: url)
        let store = await ReviewStore(fileURL: url)
        await store.waitUntilLoaded()
        let reviewed = await store.reviewedIDs
        let streak = await store.streakDays()
        XCTAssertEqual(reviewed, ["a", "b"])
        XCTAssertEqual(streak, 0, "A v6.0 file has no history; none is invented for it.")
    }

    // MARK: - Publishing

    func testNewerRevisionsReplaceOlderOnesAndStaleOnesAreDropped() async throws {
        let url = directory.appending(path: "summary.json")
        let writer = SummaryWriter(url: url)

        await writer.write(summary(marked: 1), revision: 1)
        await writer.write(summary(marked: 7), revision: 3)
        await writer.write(summary(marked: 2), revision: 2)

        let written = try JSONDecoder().decode(CleanupSummary.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.markedCount, 7, "A snapshot that lost the race must not win the file.")
    }

    func testAFailedWriteKeepsTheLastGoodFileAndRetriesOnTheNextSubmission() async throws {
        let url = directory.appending(path: "nested/summary.json")
        let writer = SummaryWriter(url: url)
        await writer.write(summary(marked: 5), revision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // The directory appearing later must not leave the revision stuck.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        await writer.write(summary(marked: 6), revision: 2)
        let written = try JSONDecoder().decode(CleanupSummary.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.markedCount, 6)
    }

    func testAMissingAppGroupIsSurvivable() async {
        let writer = SummaryWriter(url: nil)
        await writer.write(summary(marked: 1), revision: 1)  // Must not trap.
    }

    // MARK: - Helpers

    private func summary(marked: Int) -> CleanupSummary {
        CleanupSummary(markedCount: marked, totalBytesFreed: 1_024, totalPhotosDeleted: 2,
                       lastSessionDate: nil, streakDays: 1, monthBytesFreed: 512,
                       generatedAt: Date(), monthKey: "2026-09", activeDayKeys: [])
    }

    @MainActor
    private func loadedStore(days: [String: Int]) async -> ReviewStore {
        let url = directory.appending(path: "review.json")
        let payload = ["reviewed": [], "marked": [], "decisionsByDay": days] as [String: Any]
        try? JSONSerialization.data(withJSONObject: payload).write(to: url)
        let store = ReviewStore(fileURL: url)
        await store.waitUntilLoaded()
        return store
    }

    private func date(_ key: String, in calendar: Calendar = .localGregorian) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1],
                                                  day: parts[2], hour: 12))!
    }

    private func today(_ key: String) -> Date { date(key) }
}
