/// Derives view-model streams from VaultStore's observation streams.
enum ObservationMapper {
    /// A stream of `transform(value)` for every value of `source`, skipping consecutive equal
    /// results. It ends when `source` ends (rethrowing its error) and stops `source` when the
    /// consumer stops iterating.
    static func map<Input: Sendable, Output: Sendable & Equatable>(
        _ source: AsyncThrowingStream<Input, any Error>,
        _ transform: @escaping @Sendable (Input) throws -> Output
    ) -> AsyncThrowingStream<Output, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var previous: Output?
                do {
                    for try await value in source {
                        let output = try transform(value)
                        if output != previous {
                            continuation.yield(output)
                            previous = output
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
