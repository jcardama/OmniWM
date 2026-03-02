import Foundation
import Synchronization
import os

struct RunLoopTimeoutError: Error, Sendable {
    let timeout: Duration
}

// Holds the winner-election flag and continuation box for runInLoop.
// Wrapped in a class so it can be safely captured by Task closures
// (Atomic and OSAllocatedUnfairLock are both ~Copyable).
private final class RunLoopResumeState<T: Sendable>: @unchecked Sendable {
    let didResume = Atomic<Bool>(false)
    let contBox = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)

    /// Atomically claims the right to resume exactly once.
    /// Returns the continuation if this caller won the race, nil otherwise.
    func claimAndTake() -> CheckedContinuation<T, any Error>? {
        let (won, _) = didResume.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard won else { return nil }
        return contBox.withLock { cont in
            defer { cont = nil }
            return cont
        }
    }
}

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob = RunLoopJob(),
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> Void
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        job.action = action
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T: Sendable>(
        timeout: Duration = .seconds(2),
        _ body: @Sendable @escaping (RunLoopJob) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        let job = RunLoopJob()
        let state = RunLoopResumeState<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                state.contBox.withLock { $0 = cont }

                let timeoutTask = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let cont = state.claimAndTake() else { return }
                    job.cancel()
                    cont.resume(throwing: RunLoopTimeoutError(timeout: timeout))
                }

                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    guard let cont = state.claimAndTake() else { return }
                    timeoutTask.cancel()

                    do {
                        try job.checkCancellation()
                        cont.resume(returning: try body(job))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            guard let cont = state.claimAndTake() else { return }
            job.cancel()
            cont.resume(throwing: CancellationError())
        }
    }
}

final class RunLoopAction: NSObject, Sendable {
    nonisolated(unsafe) private var _action: (@Sendable (RunLoopJob) -> Void)?
    let job: RunLoopJob
    private let autoCheckCancelled: Bool

    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> Void) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
    }

    @objc func action() {
        guard let actionToRun = _action else { return }
        _action = nil
        job.action = nil
        if autoCheckCancelled, job.isCancelled { return }
        actionToRun(job)
    }

    func clearAction() {
        _action = nil
    }
}
