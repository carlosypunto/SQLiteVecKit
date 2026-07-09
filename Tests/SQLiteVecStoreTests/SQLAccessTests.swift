import Testing
import Foundation
import SQLiteVecStore

// MARK: - Raw SQL access

@Suite("VectorStore.sqlAccess")
struct SQLAccessTests {
    @Test func executeCreatesOwnTableAndInsertsWithBindings() async throws {
        try await withStore { store in
            try await store.execute("CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, pages INTEGER);")
            let changed = try await store.execute("INSERT INTO docs(id, title, pages) VALUES (?, ?, ?);",
                                                  bindings: [.int(1), .text("Manual"), .int(42)])
            #expect(changed == 1)
        }
    }

    @Test func queryReadsAllValueShapes() async throws {
        try await withStore { store in
            try await store.execute("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, n TEXT);")
            try await store.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?);",
                                    bindings: [.int(7), .double(2.5), .text("hi"),
                                               .blob(Data([0xAB, 0xCD])), .null])
            let rows = try await store.query("SELECT i, d, s, b, n FROM t;")
            #expect(rows.count == 1)
            let row = rows[0]
            #expect(row.columnNames == ["i", "d", "s", "b", "n"])
            #expect(row.int("i") == 7)
            #expect(row.double("d") == 2.5)
            #expect(row.double("i") == 7.0)     // pragmatic int -> double coercion
            #expect(row.text("s") == "hi")
            #expect(row.blob("b") == Data([0xAB, 0xCD]))
            #expect(row["n"] == .null)
            #expect(row.text("missing") == nil)
        }
    }

    @Test func queryCanJoinOwnTableWithVectorTable() async throws {
        try await withStore { store in
            try await store.execute("CREATE TABLE docs(name TEXT PRIMARY KEY, author TEXT);")
            try await store.execute("INSERT INTO docs VALUES (?, ?);", bindings: [.text("bio"), .text("Alice")])
            try await store.insert(id: 1, content: "cells divide", source: "bio", vector: [1, 0, 0])

            let rows = try await store.query("""
                SELECT c.content, d.author
                FROM chunks c JOIN docs d ON d.name = c.source
                WHERE c.id = ?;
            """, bindings: [.int(1)])
            #expect(rows.count == 1)
            #expect(rows[0].text("content") == "cells divide")
            #expect(rows[0].text("author") == "Alice")
        }
    }

    @Test func executeReturnsChangedRowCount() async throws {
        try await withStore { store in
            try await store.execute("CREATE TABLE t(v INTEGER);")
            for i in 1...4 {
                try await store.execute("INSERT INTO t VALUES (?);", bindings: [.int(i)])
            }
            let changed = try await store.execute("UPDATE t SET v = 0 WHERE v > ?;", bindings: [.int(2)])
            #expect(changed == 2)
        }
    }

    @Test func syntaxErrorSurfacesAsPrepareFailed() async throws {
        try await withStore { store in
            do {
                _ = try await store.query("SELEKT nonsense;")
                Issue.record("Expected prepareFailed")
            } catch let error as SQLiteError {
                guard case .prepareFailed = error else {
                    Issue.record("Expected .prepareFailed, got \(error)")
                    return
                }
            }
        }
    }
}
