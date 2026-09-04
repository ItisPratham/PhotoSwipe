import Foundation

/// Grants one process-wide permit for duplicate/category index work. Screen
/// view models can come and go, but two library walks must never process the
/// same index concurrently.
actor IndexScanCoordinator {
    static let shared = IndexScanCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var owner: UUID?
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []

    nonisolated func withPermit<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await acquire(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        guard acquired else { throw CancellationError() }

        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release(id)
            return result
        } catch {
            await release(id)
            throw error
        }
    }

    private func acquire(_ id: UUID) async -> Bool {
        if cancelled.remove(id) != nil { return false }
        guard owner != nil else {
            owner = id
            return true
        }
        return await withCheckedContinuation { continuation in
            if cancelled.remove(id) != nil {
                continuation.resume(returning: false)
            } else {
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard owner != id else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        } else {
            // Cancellation can race ahead of `acquire`; remember it so that
            // the later acquire does not enter the queue.
            cancelled.insert(id)
        }
    }

    private func release(_ id: UUID) {
        guard owner == id else { return }

        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if cancelled.remove(next.id) != nil {
                next.continuation.resume(returning: false)
                continue
            }
            owner = next.id
            next.continuation.resume(returning: true)
            return
        }

        owner = nil
    }
}
