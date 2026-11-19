import Testing

/// The growth check must tell linear from quadratic work by itself, or the tests that use it prove nothing.
@Suite("Growth measurement")
struct GrowthTests {
    @Test func linearWorkPasses() async {
        let growth = await measureGrowth(size: 200_000, make: { Array(0..<$0) }, run: { $0.reduce(0, &+) })
        #expect(growth.isLinear, "\(growth)")
    }

    @Test func quadraticWorkFails() async {
        let growth = await measureGrowth(size: 300, make: { Array(0..<$0) }, run: { values in
            var pairs = 0
            for a in values { for b in values where a &+ b == values.count { pairs &+= 1 } }
            return pairs
        })
        #expect(!growth.isLinear, "\(growth)")
    }
}
