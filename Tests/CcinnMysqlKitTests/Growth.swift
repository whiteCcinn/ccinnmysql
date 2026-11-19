import Foundation

/// How much longer some work takes on an input `factor` times larger.
///
/// Linear work grows about `factor`-fold and quadratic work about `factor²`-fold, on any machine. A busy CI runner slows
/// both sizes alike, and the fastest of several interleaved runs drops the passes the scheduler interrupted. A wall-clock
/// bound instead fails whenever the runner is busy: `pathologicalNestingStaysLinear` took 10.3 s against its 10 s bound
/// on CI, for work that takes 0.8 s locally.
struct Growth: Sendable, CustomStringConvertible {
    let size: Int
    let factor: Int
    /// The fastest run at `size` and at `size × factor`.
    let small: Duration
    let large: Duration

    var ratio: Double { Self.seconds(large) / max(Self.seconds(small), 1e-6) }

    /// Linear or n·log n growth, with 3× room for noise. Quadratic growth is about `factor` times larger still.
    var isLinear: Bool { ratio < Double(factor * 3) }

    var description: String {
        "n = \(size): \(small), \(factor)n: \(large), ×\(String(format: "%.1f", ratio)) (linear ≈ ×\(factor), quadratic ≈ ×\(factor * factor))"
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}

/// Measures `run` on `make(size)` and `make(size × factor)`, `repeats` times each, interleaved, on a thread of its own.
/// Inputs are made before timing starts.
func measureGrowth<Input, Output>(size: Int, factor: Int = 8, repeats: Int = 3,
                                  make: @escaping @Sendable (Int) -> Input,
                                  run: @escaping @Sendable (Input) -> Output) async -> Growth {
    await onDedicatedThread {
        let smallInput = make(size)
        let largeInput = make(size * factor)
        let clock = ContinuousClock()
        var small = Duration.seconds(86_400)
        var large = Duration.seconds(86_400)
        for _ in 0..<max(repeats, 1) {
            small = min(small, clock.measure { keep(run(smallInput)) })
            large = min(large, clock.measure { keep(run(largeInput)) })
        }
        return Growth(size: size, factor: factor, small: small, large: large)
    }
}

/// Keeps a result alive so an optimised build cannot drop the work that produced it.
@inline(never)
private func keep<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
