import Foundation
import Parser
import RNGLR_Parser

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count <= 1 else {
        throw NSError(
            domain: "rnglr-microbenchmark", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "usage: rnglr-microbenchmark [output.json]"]
        )
    }
    #if DEBUG
    let configuration = ParserEngineMicrobenchmarkSuite.BuildConfiguration.debug
    #else
    let configuration = ParserEngineMicrobenchmarkSuite.BuildConfiguration.release
    #endif
    let report = try RNGLRMicrobenchmarks.run(buildConfiguration: configuration)
    let data = try ParserEngineMicrobenchmarkCodec.encode(report)
    if let output = arguments.first {
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("rnglr-microbenchmark: \(error)\n".utf8))
    exit(1)
}
