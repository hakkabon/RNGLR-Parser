import Parser
import Testing
@testable import RNGLR_Parser

@Test("RNGLR owns a reproducible executable microbenchmark")
func rnglrMicrobenchmark() throws {
    let report = try RNGLRMicrobenchmarks.run(
        buildConfiguration: .release, warmupIterations: 0, measurementIterations: 3,
        environment: .init(
            operatingSystem: "test", architecture: "test",
            processorCount: 1, physicalMemoryBytes: 1
        )
    )
    #expect(report.suite.owner.repository == "RNGLR-Parser")
    #expect(report.suite.engineID == "rnglr")
    #expect(report.results.first?.counters["accepted"] == 1)
    #expect(report.results.first?.counters["ambiguous"] == 1)
    #expect((report.results.first?.counters["forestNodeCount"] ?? 0) > 0)
}
