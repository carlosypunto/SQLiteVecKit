// The three retrieval modes: vector (semantic), lexical (BM25), and hybrid
// (Reciprocal Rank Fusion).

// snippet.hide
import Foundation
import SQLiteVecStore

private func embed(_ text: String) -> [Float] { Array(repeating: 0, count: 512) }

private struct ChunkInfo: Codable { let page: Int; let section: String }

func searching(store: VectorStore, question: String) async throws {
// snippet.show
// Semantic: embed the query with the SAME model used at ingestion.
let semantic = try await store.search(vector: embed(question), topK: 5)
for hit in semantic {
    print(hit.content, hit.distance)               // lower distance = more similar
    if let info = try hit.decodeMetadata(ChunkInfo.self) {
        print("page \(info.page)")
    }
}

// Lexical: FTS5 syntax — terms, "phrases", AND/OR/NOT, prefix*.
// BM25 score travels in `distance` (negative; lower = better).
let lexical = try await store.searchText("mitochondria", topK: 5)

// Hybrid: RRF fusion of both lists; `score` is HIGHER = better.
let hybrid = try await store.searchHybrid(text: question, vector: embed(question), topK: 5)
for hit in hybrid {
    print(hit.content, hit.score, hit.vectorRank ?? "-", hit.textRank ?? "-")
}

// Restrict any search to one document:
let scoped = try await store.search(vector: embed(question), topK: 5, source: "biology_notes.txt")
// snippet.hide
    _ = (lexical, scoped)
}
// snippet.show
