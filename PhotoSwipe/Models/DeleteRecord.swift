import Foundation

/// One successful batch delete. Captured after PhotoKit confirms removal so
/// the record represents photos that are actually gone from the library.
struct DeleteRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let count: Int
    let bytesFreed: Int64

    init(id: UUID = UUID(), date: Date = Date(), count: Int, bytesFreed: Int64) {
        self.id = id
        self.date = date
        self.count = count
        self.bytesFreed = bytesFreed
    }
}
