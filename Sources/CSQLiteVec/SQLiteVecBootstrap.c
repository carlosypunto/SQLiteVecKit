#include "SQLiteVecBootstrap.h"
#include "sqlite-vec.h"

int sqlite_vec_bootstrap(sqlite3 *db) {
    return sqlite3_vec_init(db, 0, 0);
}

const char *sqlite_vec_bundled_version(void) {
    return SQLITE_VEC_VERSION;
}
