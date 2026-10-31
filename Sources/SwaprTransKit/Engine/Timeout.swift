import Foundation

struct TimedOut: Error {}

/// Runs `operation` and returns its result, or throws `TimedOut` after `seconds`.
///
/// Unlike a task group, this doesn't wait for the operation once the time is up: some system
/// calls (Apple's translation session for a missing language model) never return and ignore
/// cancellation. The abandoned task is cancelled and left to finish by itself.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OneShot(continuation)
        let work = Task {
            do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if gate.finish(.failure(TimedOut())) { work.cancel() }
        }
    }
}

/// Resumes a continuation only for the first result.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// True when this call delivered the result.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(with: result)
        return true
    }
}
