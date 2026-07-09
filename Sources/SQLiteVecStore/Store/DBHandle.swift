import CSQLiteVec

// Owns the sqlite3 handle and closes it on dealloc, solving the actor deinit isolation problem.
final class DBHandle: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ ptr: OpaquePointer) { self.ptr = ptr }
    deinit { sqlite3_close(ptr) }
}
