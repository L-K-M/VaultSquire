import Foundation

/// A one-at-a-time gate for operations that must not overlap.
///
/// Vaultwarden's refresh token rotates on every refresh, and the Keychain
/// credential store's load-then-update is explicitly not atomic across
/// threads: its contract requires callers to serialize concurrent writes for
/// one account. Two overlapping account operations (a sync and a write, each
/// having built its own refresher from the same stored token) can therefore
/// race a rotation — one operation's rotated token is lost, or a server that
/// invalidates on rotation hands the loser a spurious session-expired. This
/// gate serializes those operations so exactly one reads, refreshes, and
/// persists at a time.
///
/// The implementation is a task chain rather than a plain actor method because
/// actors are re-entrant: a suspending `await` inside an actor method lets the
/// next caller in. Chaining on the previous operation's task keeps the order
/// strictly first-come-first-served. A caller that is cancelled while queued
/// still runs its operation when its turn comes — a cancelled sync must not
/// wedge the queue for the operations behind it.
actor SerialOperationGate {
    private var tail: Task<Void, Never>?

    /// Runs `operation` after every previously enqueued operation has finished,
    /// in submission order.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let current = Task<T, Never> { [previous] in
            if let previous {
                await previous.value
            }
            return await operation()
        }
        // The chain carries only completion, not the value; discarding it here
        // keeps `tail` a uniform `Task<Void, Never>`.
        tail = Task { _ = await current.value }
        return await current.value
    }
}
