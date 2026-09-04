import Foundation

/// Identifiable sheet payload so a picker is presented only after its
/// asynchronous candidate fetch has completed.
struct PersonCandidateList: Identifiable {
    let id = UUID()
    let candidates: [PersonCluster]
}
