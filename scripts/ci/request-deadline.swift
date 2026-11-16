import Foundation

struct ProbeRequestTimedOut: Error, CustomStringConvertible {
    let caseName: String
    let stage: String
    let seconds: TimeInterval
    var description: String { "案例「\(caseName)」的\(stage)於 \(seconds) 秒逾時，已取消請求" }
}

@MainActor
private final class RequestDeadlineState<T> {
    var continuation: CheckedContinuation<T, Error>?
    var operation: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        operation = nil
        continuation.resume(with: result)
    }

    func cancel(_ error: Error) {
        operation?.cancel()
        finish(.failure(error))
    }
}

@MainActor
func withRequestDeadline<T>(caseName: String, stage: String, seconds: TimeInterval = 60,
                            operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let state = RequestDeadlineState<T>()
    return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            state.operation = Task { @MainActor in
                do {
                    let value = try await operation()
                    state.finish(.success(value))
                } catch {
                    state.finish(.failure(error))
                }
            }
            state.timer = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                state.cancel(ProbeRequestTimedOut(caseName: caseName, stage: stage, seconds: seconds))
            }
        }
    }, onCancel: {
        Task { @MainActor in state.cancel(CancellationError()) }
    })
}
