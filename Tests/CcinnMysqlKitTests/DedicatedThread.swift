import Foundation

/// Runs CPU-heavy test work (fuzzing, linear-time checks over huge inputs, Unicode enumeration) on a thread of its own
/// instead of the cooperative pool: on a 3-core CI runner such work held the pool's threads, and unrelated cancellation and
/// deadline tests missed their bounds. Assertions stay in the test's task (`#expect` needs it), so the work returns what to
/// check.
func onDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = 16 << 20 // deeply nested inputs recurse further than the default 512 KB allows
        thread.start()
    }
}
