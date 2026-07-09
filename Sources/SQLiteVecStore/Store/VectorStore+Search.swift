import CSQLiteVec

// MARK: - Vector, lexical, and hybrid search

extension VectorStore {
    /// K-nearest-neighbors search, ordered by ascending distance (best first).
    ///
    /// - Parameters:
    ///   - vector: Query embedding; must come from the same model as the
    ///     stored embeddings and match the store dimension.
    ///   - topK: Number of neighbors, in `1...maxTopK`.
    ///   - source: Restricts the search to rows with that source. Applied
    ///     *inside* the KNN query, so `topK` counts only matching rows.
    ///   - sqlWhere: Optional SQL fragment applied *after* the KNN selection
    ///     (post-filter: fewer than `topK` rows may come back — raise `topK`
    ///     when filtering). It sees the columns `id`, `content`, `source`,
    ///     `metadata`, `distance`. Write values as `?` placeholders and pass
    ///     them in `bindings` — never interpolate values into the fragment.
    ///     Example: `where: "json_extract(metadata, '$.page') > ?", bindings: [.int(10)]`.
    ///   - bindings: Values for the fragment's `?` placeholders, in order.
    public func search(
        vector: [Float],
        topK: Int = 5,
        source: String? = nil,
        where sqlWhere: String? = nil,
        bindings: [SQLValue] = []
    ) throws -> [SearchResult] {
        try validateDimension(of: vector)
        guard (1...Self.maxTopK).contains(topK) else { throw SQLiteError.invalidTopK(topK) }

        // `AND k = ?` instead of `LIMIT ?`: LIMIT only works as a KNN constraint
        // on SQLite 3.41+ and breaks when the query involves JOINs.
        let sourceFilter = source != nil ? " AND source = ?" : ""
        let knnQuery = """
            SELECT id, content, source, metadata, distance
            FROM \(tableName)
            WHERE embedding MATCH ? AND k = ?\(sourceFilter)
        """
        // metadata lives in an aux column, which vec0 cannot filter inside the
        // KNN query — the fragment runs as a post-filter on the topK selection.
        // MATERIALIZED is load-bearing: without it, SQLite's WHERE push-down
        // optimization moves the fragment into the KNN query, where vec0
        // rejects constraints on auxiliary columns.
        let sql: String = if let sqlWhere {
            "WITH knn AS MATERIALIZED (\(knnQuery)) SELECT * FROM knn WHERE (\(sqlWhere)) ORDER BY distance;"
        } else {
            knnQuery + " ORDER BY distance;"
        }

        return try withStatement(sql) { ptr, statement in
            var index: Int32 = 1
            vector.withUnsafeBytes { rawBuffer in
                _ = sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
            index += 1
            sqlite3_bind_int64(statement, index, Int64(topK))
            index += 1
            if let source {
                sqlite3_bind_text(statement, index, source, -1, SQLITE_TRANSIENT)
                index += 1
            }
            Self.bind(bindings, to: statement, startingAt: index)
            return try Self.collectResults(ptr: ptr, statement: statement)
        }
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    /// Disfavored so numeric-literal arrays keep resolving to the [Float] overload.
    @_disfavoredOverload
    public func search(
        vector: [Double],
        topK: Int = 5,
        source: String? = nil,
        where sqlWhere: String? = nil,
        bindings: [SQLValue] = []
    ) throws -> [SearchResult] {
        try search(vector: vector.map(Float.init), topK: topK, source: source,
                   where: sqlWhere, bindings: bindings)
    }

    /// Full-text (lexical) search over `content`, powered by the companion
    /// FTS5 index and ranked by BM25 (`SearchResult.distance` carries the BM25
    /// score: negative, lower = better).
    ///
    /// `query` uses FTS5 query syntax: bare terms, `"exact phrases"`,
    /// `AND`/`OR`/`NOT`, and `prefix*`. A malformed query throws
    /// `SQLiteError.invalidTextQuery`. Requires `lexicalSearch: true` (the
    /// default) — otherwise throws `SQLiteError.lexicalSearchDisabled`.
    ///
    /// `sqlWhere` is an ordinary WHERE condition here (no post-filter caveat).
    /// Bare column names (`id`, `source`, `metadata`) resolve to the vec0
    /// table; only `content` is ambiguous in the FTS join — qualify it as
    /// `c.content`. Values go in `bindings`.
    public func searchText(
        _ query: String,
        topK: Int = 5,
        source: String? = nil,
        where sqlWhere: String? = nil,
        bindings: [SQLValue] = []
    ) throws -> [SearchResult] {
        guard lexicalSearch else { throw SQLiteError.lexicalSearchDisabled }
        guard (1...Self.maxTopK).contains(topK) else { throw SQLiteError.invalidTopK(topK) }

        let sourceFilter = source != nil ? " AND c.source = ?" : ""
        let whereClause = sqlWhere.map { " AND (\($0))" } ?? ""
        let sql = """
            SELECT c.id, c.content, c.source, c.metadata, bm25(\(ftsTableName)) AS score
            FROM \(ftsTableName)
            JOIN \(tableName) AS c ON c.id = \(ftsTableName).rowid
            WHERE \(ftsTableName) MATCH ?\(sourceFilter)\(whereClause)
            ORDER BY score
            LIMIT ?;
        """
        do {
            return try withStatement(sql) { ptr, statement in
                var index: Int32 = 1
                sqlite3_bind_text(statement, index, query, -1, SQLITE_TRANSIENT)
                index += 1
                if let source {
                    sqlite3_bind_text(statement, index, source, -1, SQLITE_TRANSIENT)
                    index += 1
                }
                index = Self.bind(bindings, to: statement, startingAt: index)
                sqlite3_bind_int64(statement, index, Int64(topK))
                return try Self.collectResults(ptr: ptr, statement: statement)
            }
        } catch SQLiteError.stepFailed(_, let message) {
            // FTS5 reports malformed query syntax when the bound query is
            // first evaluated, i.e. at step time.
            throw SQLiteError.invalidTextQuery(query, detail: message)
        }
    }

    /// Hybrid retrieval: runs `search` and `searchText` (each overfetched to
    /// `min(topK * 4, maxTopK)`) and fuses them with Reciprocal Rank Fusion
    /// (k = 60). Results are ordered by descending `score`; ties break by id.
    /// Requires `lexicalSearch: true` (the default).
    ///
    /// `sqlWhere`/`bindings` are forwarded to **both** underlying searches, so
    /// the fragment must be valid in both contexts: use the bare column names
    /// (`metadata`, `source`, …) qualified nowhere — they resolve in the KNN
    /// post-filter — and avoid `content`, which is ambiguous in the FTS join.
    public func searchHybrid(
        text: String,
        vector: [Float],
        topK: Int = 5,
        source: String? = nil,
        where sqlWhere: String? = nil,
        bindings: [SQLValue] = []
    ) throws -> [HybridSearchResult] {
        guard lexicalSearch else { throw SQLiteError.lexicalSearchDisabled }
        guard (1...Self.maxTopK).contains(topK) else { throw SQLiteError.invalidTopK(topK) }
        let fetchK = min(topK * 4, Self.maxTopK)
        let vectorResults = try search(vector: vector, topK: fetchK, source: source,
                                       where: sqlWhere, bindings: bindings)
        let textResults = try searchText(text, topK: fetchK, source: source,
                                         where: sqlWhere, bindings: bindings)

        struct Fused {
            var content: String
            var source: String
            var metadata: String?
            var score: Double
            var vectorRank: Int?
            var textRank: Int?
        }
        let rrfK = 60.0
        var fusedByID: [Int: Fused] = [:]
        for (offset, result) in vectorResults.enumerated() {
            let rank = offset + 1
            fusedByID[result.id] = Fused(
                content: result.content, source: result.source, metadata: result.metadata,
                score: 1.0 / (rrfK + Double(rank)), vectorRank: rank, textRank: nil
            )
        }
        for (offset, result) in textResults.enumerated() {
            let rank = offset + 1
            let contribution = 1.0 / (rrfK + Double(rank))
            if var fused = fusedByID[result.id] {
                fused.score += contribution
                fused.textRank = rank
                fusedByID[result.id] = fused
            } else {
                fusedByID[result.id] = Fused(
                    content: result.content, source: result.source, metadata: result.metadata,
                    score: contribution, vectorRank: nil, textRank: rank
                )
            }
        }

        var ranked: [HybridSearchResult] = fusedByID.map { pair in
            HybridSearchResult(
                id: pair.key, content: pair.value.content, source: pair.value.source,
                metadata: pair.value.metadata, score: pair.value.score,
                vectorRank: pair.value.vectorRank, textRank: pair.value.textRank
            )
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.id < rhs.id : lhs.score > rhs.score
        }
        return Array(ranked.prefix(topK))
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    @_disfavoredOverload
    public func searchHybrid(
        text: String,
        vector: [Double],
        topK: Int = 5,
        source: String? = nil,
        where sqlWhere: String? = nil,
        bindings: [SQLValue] = []
    ) throws -> [HybridSearchResult] {
        try searchHybrid(text: text, vector: vector.map(Float.init), topK: topK,
                         source: source, where: sqlWhere, bindings: bindings)
    }
}
