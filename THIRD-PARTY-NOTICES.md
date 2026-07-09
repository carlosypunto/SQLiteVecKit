# Third-Party Notices

SQLiteVecKit bundles third-party source code. Their licenses and copyright
notices are reproduced below and alongside the vendored files.

## sqlite-vec

- Upstream: https://github.com/asg017/sqlite-vec
- Vendored version: **v0.1.9** (pinned in `scripts/vendor-sqlite-vec.sh`)
- Files: `Sources/CSQLiteVec/sqlite-vec.c`, `Sources/CSQLiteVec/sqlite-vec.h`
- Modifications: **none** — the amalgamation is vendored verbatim.
- Copyright (c) 2024 Alex Garcia
- Licensed under **MIT OR Apache-2.0**. Full texts:
  `Sources/CSQLiteVec/LICENSE-MIT` and
  `Sources/CSQLiteVec/LICENSE-APACHE`.
- Integrity: SHA-256 checksums for `sqlite-vec.c`/`sqlite-vec.h` are locked in
  `Sources/CSQLiteVec/checksums.lock` and verified by
  `scripts/vendor-sqlite-vec.sh verify`, which runs in CI on every push/PR
  (`.github/workflows/vendor-check.yml`) and can optionally run as a local
  `pre-push` hook (`.githooks/pre-push`).
