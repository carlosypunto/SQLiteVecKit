import Foundation
import CSQLiteVec

/// An on-device vector store backed by SQLite and the bundled sqlite-vec
/// extension, with companion full-text (FTS5) and hybrid retrieval.
///
/// `VectorStore` is an actor: share it freely across tasks and call every
/// method with `await`. Each instance owns one SQLite connection; rows live in
/// a `vec0` virtual table plus an FTS5 index over `content` that the store
/// keeps in sync automatically.
///
/// The store's configuration (`dimension`, `distanceMetric`, table layout) is
/// frozen into the database file on first creation — reopening with a
/// different configuration throws ``SQLiteError/schemaMismatch(expected:found:)``.
public actor VectorStore {
    // MARK: - State

    // Internal (not private): the public API lives in the VectorStore+*.swift
    // extension files, which need direct access to the connection and the
    // frozen configuration.
    var handle: DBHandle?
    let dimension: Int
    let distanceMetric: DistanceMetric
    let tableName: String
    let metadataByteLimit: Int
    let lexicalSearch: Bool

    /// Name of the companion FTS5 table mirroring `content` for lexical search.
    var ftsTableName: String { Self.ftsTableName(for: tableName) }

    // MARK: - Constants

    /// The version of the bundled sqlite-vec amalgamation, for example `"v0.1.9"`.
    /// This is diagnostic information; SQLiteVecKit's own SemVer is independent.
    public static var bundledVecVersion: String {
        String(cString: sqlite_vec_bundled_version())
    }

    /// Default cap for `VectorEntry.metadata` size (UTF-8 bytes).
    /// Metadata lives in a vec0 auxiliary column, so storage is cheap, but an
    /// explicit bound keeps rows from silently growing unbounded JSON blobs.
    public static let defaultMetadataByteLimit = 16_384

    /// Upper bound for `topK`, matching sqlite-vec's vec_max_k limit.
    public static let maxTopK = 4096

    // MARK: - Init

    /// Opens (or creates) the database at `path`, registers sqlite-vec on the
    /// connection, and creates the vec0 + FTS5 tables if missing.
    ///
    /// - Parameters:
    ///   - path: Filesystem path of the SQLite file (created if absent).
    ///   - dimension: Embedding length; must equal your embedding model's
    ///     output size. Frozen into the file on first creation.
    ///   - distanceMetric: `.cosine` (default) or `.l2`. Also frozen.
    ///   - tableName: Restricted to `[A-Za-z_][A-Za-z0-9_]*`.
    ///   - metadataByteLimit: Per-row cap for `metadata`, in UTF-8 bytes.
    ///   - lexicalSearch: Whether to maintain the FTS5 companion index that
    ///     powers `searchText`/`searchHybrid`. Frozen into the file: reopening
    ///     with the opposite value throws `.schemaMismatch`.
    /// - Throws: ``SQLiteError`` — notably `.schemaMismatch` when the file was
    ///   created with a different configuration.
    public init(
        dbPath path: String,
        dimension: Int = 512,
        distanceMetric: DistanceMetric = .cosine,
        tableName: String = "chunks",
        metadataByteLimit: Int = VectorStore.defaultMetadataByteLimit,
        lexicalSearch: Bool = true
    ) throws {
        guard Self.isValidTableName(tableName) else {
            throw SQLiteError.invalidTableName(tableName)
        }
        guard dimension >= 1 else {
            throw SQLiteError.invalidDimension(dimension)
        }
        self.dimension = dimension
        self.distanceMetric = distanceMetric
        self.tableName = tableName
        self.metadataByteLimit = metadataByteLimit
        self.lexicalSearch = lexicalSearch

        var ptr: OpaquePointer?
        let openCode = sqlite3_open(path, &ptr)
        guard openCode == SQLITE_OK, let ptr else {
            if let ptr { sqlite3_close(ptr) }
            throw SQLiteError.databaseOpenFailed(code: openCode, message: nil)
        }

        let rc = sqlite_vec_bootstrap(ptr)
        guard rc == SQLITE_OK else {
            let msg = Self.errorMessage(from: ptr)
            sqlite3_close(ptr)
            throw SQLiteError.registrationFailed(code: rc, message: msg)
        }

        self.handle = DBHandle(ptr)
        try Self.setUpSchema(
            ptr: ptr,
            dimension: dimension,
            distanceMetric: distanceMetric,
            tableName: tableName,
            lexicalSearch: lexicalSearch
        )
    }

    /// Opens (or creates) the database at `dbURL`.
    ///
    /// This is a URL-based convenience for
    /// ``init(dbPath:dimension:distanceMetric:tableName:metadataByteLimit:lexicalSearch:)``.
    ///
    /// - Parameters:
    ///   - dbURL: File URL of the SQLite database.
    ///   - dimension: Embedding length; frozen into the file on first creation.
    ///   - distanceMetric: `.cosine` (default) or `.l2`. Also frozen.
    ///   - tableName: Restricted to `[A-Za-z_][A-Za-z0-9_]*`.
    ///   - metadataByteLimit: Per-row cap for `metadata`, in UTF-8 bytes.
    ///   - lexicalSearch: Whether to maintain the FTS5 companion index.
    /// - Throws: ``SQLiteError`` for invalid configuration, open failure,
    ///   sqlite-vec registration failure, or schema mismatch.
    public init(
        dbURL: URL,
        dimension: Int = 512,
        distanceMetric: DistanceMetric = .cosine,
        tableName: String = "chunks",
        metadataByteLimit: Int = VectorStore.defaultMetadataByteLimit,
        lexicalSearch: Bool = true
    ) throws {
        try self.init(
            dbPath: dbURL.path,
            dimension: dimension,
            distanceMetric: distanceMetric,
            tableName: tableName,
            metadataByteLimit: metadataByteLimit,
            lexicalSearch: lexicalSearch
        )
    }
}
