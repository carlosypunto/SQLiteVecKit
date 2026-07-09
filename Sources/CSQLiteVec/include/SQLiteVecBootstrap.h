// This include also re-exports the system sqlite3 API to Swift consumers
// of the CSQLiteVec module (VectorStore uses sqlite3_open, sqlite3_prepare_v2, ...).
#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

int sqlite_vec_bootstrap(sqlite3 *db);

/// Returns the bundled sqlite-vec version string (SQLITE_VEC_VERSION), e.g. "v0.1.9".
const char *sqlite_vec_bundled_version(void);

#ifdef __cplusplus
}
#endif
