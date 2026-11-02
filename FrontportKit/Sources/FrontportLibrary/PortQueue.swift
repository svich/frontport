import FrontportCore
import os

/// One operation per Port at a time: the others for that Port wait their turn, in the order they asked. The Library and
/// the Device Library each keep one.
final class PortQueue: Sendable {
    private struct State: Sendable {
        var busy: Set<PortID> = []
        var waiting: [PortID: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns once the Port is the caller's: at once when nothing holds it, otherwise when its turn comes.
    func acquire(_ port: PortID) async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.busy.insert(port).inserted {
                    continuation.resume()
                } else {
                    state.waiting[port, default: []].append(continuation)
                }
            }
        }
    }

    /// Hands the Port to the next caller waiting for it, or frees it.
    func release(_ port: PortID) {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard var queue = state.waiting[port], !queue.isEmpty else {
                state.busy.remove(port)
                return nil
            }
            let next = queue.removeFirst()
            state.waiting[port] = queue.isEmpty ? nil : queue
            return next
        }
        next?.resume()
    }
}
