import Foundation

/// Runs main-actor async jobs strictly one after another, and lets the owner
/// cancel *everything* that has been requested so far — the job currently
/// executing as well as any that are still waiting behind it.
///
/// The scan view models use this so that:
/// - a library-change notification arriving mid-scan queues a follow-up run
///   instead of replacing the handle to the scan that's actually running;
/// - Cancel therefore always reaches the real scan, and
/// - a run requested right after Cancel waits for the cancelled one to unwind
///   (its `defer`/`catch` state resets) instead of racing it.
@MainActor
final class SerialTaskQueue {
    private var tasks: [Task<Void, Never>] = []

    /// Whether any job is executing or waiting.
    var isBusy: Bool { !tasks.isEmpty }

    /// Appends `job` to run after every previously enqueued job has finished.
    /// A job that was cancelled while waiting is skipped entirely.
    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = tasks.last
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await job()
        }
        tasks.append(task)
        Task { @MainActor [weak self] in
            _ = await task.value
            self?.tasks.removeAll { $0 == task }
        }
    }

    /// Cancels the running job and drops every waiting one. The running job
    /// still unwinds through its own `catch`/`defer` before anything enqueued
    /// afterwards begins.
    func cancelAll() {
        for task in tasks { task.cancel() }
    }
}
