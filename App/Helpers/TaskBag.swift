import os

/// Owns long-running observation tasks of a view model and cancels them when the view model goes
/// away (its deinit cannot touch main-actor state). Cancelling ends `for try await` loops over
/// the VaultData observation streams.
nonisolated final class TaskBag: Sendable {
    private let tasks = OSAllocatedUnfairLock<[String: Task<Void, Never>]>(initialState: [:])

    init() {}

    /// Stores `task` under `key`, cancelling the task it replaces.
    func set(_ key: String, _ task: Task<Void, Never>) {
        let previous = tasks.withLock { tasks in
            defer { tasks[key] = task }
            return tasks[key]
        }
        previous?.cancel()
    }

    /// Cancels and forgets the task under `key`.
    func cancel(_ key: String) {
        let task = tasks.withLock { $0.removeValue(forKey: key) }
        task?.cancel()
    }

    func cancelAll() {
        let all = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in all {
            task.cancel()
        }
    }

    deinit {
        cancelAll()
    }
}
