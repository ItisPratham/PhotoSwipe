import Foundation

/// One reversible deck decision, pushed by `SwipeViewModel` on every swipe and
/// popped by Undo. The stack is per session and capped (`SwipeViewModel.undoLimit`);
/// it is never persisted, since a relaunch already resets the deck cursor.
struct UndoEntry: Equatable {
    /// The card that was decided. Undo re-validates this against the live
    /// deck: a card that vanished (batch-deleted, or dropped by a silent
    /// refresh) is skipped rather than replayed.
    let assetID: String
}
