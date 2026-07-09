// Compile shim for the unmodified upstream amalgamation.
// SQLITE_VEC_ENABLE_NEON is NOT internally guarded by __ARM_NEON in
// sqlite-vec.c (it unconditionally includes <arm_neon.h>), and SPM cSettings
// cannot be applied per-architecture, so the arch guard lives here.
// sqlite-vec.c must never be compiled directly; it is included below so the
// define is in effect. AVX is deliberately not enabled (__AVX2__ is not set
// by the default x86_64-apple clang target).
#if defined(__aarch64__) || defined(__ARM_NEON)
#define SQLITE_VEC_ENABLE_NEON
#endif
#include "sqlite-vec.c"
