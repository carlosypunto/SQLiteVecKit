// Filter searches with a SQL fragment. Values ALWAYS go through `bindings:`
// as `?` placeholders — never interpolated into the fragment.

// snippet.hide
import Foundation
import SQLiteVecStore

private func embed(_ text: String) -> [Float] { Array(repeating: 0, count: 512) }

func filteringWithSQL(store: VectorStore, question: String) async throws {
// snippet.show
// In `search` the fragment runs AFTER the KNN selection (post-filter):
// fewer than topK rows may come back — raise topK when filtering.
let filtered = try await store.search(
    vector: embed(question),
    topK: 20,
    where: "json_extract(metadata, '$.lang') = ? AND json_extract(metadata, '$.page') > ?",
    bindings: [.text("en"), .int(10)]
)

// If the UI needs 5 filtered vector hits, overfetch and trim.
let candidates = try await store.search(
    vector: embed(question),
    topK: 50,
    where: "json_extract(metadata, '$.section') = ?",
    bindings: [.text("Cells")]
)
let visible = Array(candidates.prefix(5))

// In `searchText` the fragment is an ordinary WHERE condition
// (qualify `content` as c.content there — the bare name is ambiguous).
let lexical = try await store.searchText(
    "cell",
    where: "json_extract(metadata, '$.page') <= ?",
    bindings: [.int(50)]
)
// snippet.hide
    _ = (filtered, visible, lexical)
}
// snippet.show
