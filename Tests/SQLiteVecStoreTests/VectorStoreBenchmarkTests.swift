import Foundation
import Testing
import SQLiteVecStore

@Suite("VectorStoreBenchmark")
struct VectorStoreBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQLITEVECKIT_RUN_BENCHMARKS"] == "1"))
    func vectorStoreBenchmark() async throws {
        let dimension = 64
        let rowCounts = [500, 2_500, 5_000]
        let configuration = buildConfiguration
        let processInfo = ProcessInfo.processInfo

        print("SQLiteVecKit benchmark")
        print("Host: \(processInfo.hostName)")
        print("OS: \(processInfo.operatingSystemVersionString)")
        print("Processors: \(processInfo.processorCount)")
        print("Build: \(configuration)")
        print("Dimension: \(dimension)")

        for rowCount in rowCounts {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("SQLiteVecKitBenchmark-\(UUID().uuidString).sqlite")
                .path
            defer { try? FileManager.default.removeItem(atPath: path) }

            let store = try VectorStore(dbPath: path, dimension: dimension)
            let entries = (1...rowCount).map { id in
                VectorEntry(
                    id: id,
                    content: benchmarkContent(id: id),
                    source: "doc-\(id % 25)",
                    metadata: #"{"bucket":\#(id % 10)}"#,
                    vector: benchmarkVector(id: id, dimension: dimension)
                )
            }
            let queryVector = benchmarkVector(id: rowCount / 2, dimension: dimension)

            print("Rows: \(rowCount)")
            // insertBatch mutates the store, so it can only run once per store.
            try await measureOnce("insertBatch") {
                try await store.insertBatch(entries)
            }
            try await measureMedian("search") {
                _ = try await store.search(vector: queryVector, topK: 10)
            }
            try await measureMedian("searchText") {
                _ = try await store.searchText("topic7 alpha", topK: 10)
            }
            try await measureMedian("searchHybrid") {
                _ = try await store.searchHybrid(text: "topic7 alpha", vector: queryVector, topK: 10)
            }
        }
    }

    private var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private func benchmarkContent(id: Int) -> String {
        let parity = id.isMultiple(of: 2) ? "alpha" : "beta"
        return "Synthetic chunk \(id) topic\(id % 10) \(parity) local vector search benchmark text."
    }

    private func benchmarkVector(id: Int, dimension: Int) -> [Float] {
        (0..<dimension).map { index in
            let value = ((id + 17) * (index + 3)) % 101
            return Float(value + 1) / 102.0
        }
    }

    private func timed(_ operation: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private func measureOnce(_ label: String, _ operation: () async throws -> Void) async rethrows {
        let milliseconds = try await timed(operation)
        print("  \(label): \(String(format: "%.2f", milliseconds)) ms")
    }

    /// One warmup call, then the median of `iterations` timed runs — single
    /// cold measurements of the read paths are too noisy to compare.
    private func measureMedian(
        _ label: String,
        iterations: Int = 5,
        _ operation: () async throws -> Void
    ) async rethrows {
        try await operation()  // warmup
        var samples: [Double] = []
        for _ in 0..<iterations {
            samples.append(try await timed(operation))
        }
        let median = samples.sorted()[samples.count / 2]
        print("  \(label): \(String(format: "%.2f", median)) ms (median of \(iterations))")
    }
}
