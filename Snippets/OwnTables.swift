// Keep your own tables in the same database file and join them against the
// vector table. Conventions: read the store's vec0 table freely, write to it
// only through the typed API, and never touch the internal `<table>_fts` index.

// snippet.hide
import Foundation
import SQLiteVecStore

func ownTables(store: VectorStore) async throws {
// snippet.show
try await store.execute("CREATE TABLE IF NOT EXISTS docs(name TEXT PRIMARY KEY, author TEXT)")
try await store.execute("INSERT INTO docs VALUES (?, ?)",
                        bindings: [.text("biology_notes.txt"), .text("Alice")])

let rows = try await store.query("""
    SELECT c.content, d.author
    FROM chunks c JOIN docs d ON d.name = c.source
    WHERE c.id = ?
    """, bindings: [.int(1)])

for row in rows {
    let content = row.text("content")   // typed accessors return Optionals
    let author = row.text("author")
    print(content ?? "-", author ?? "-")
}

let changed = try await store.execute("UPDATE docs SET author = ? WHERE name = ?",
                                      bindings: [.text("Bob"), .text("biology_notes.txt")])
print("\(changed) row(s) updated")
// snippet.hide
}
// snippet.show
