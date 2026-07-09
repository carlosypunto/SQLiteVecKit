# Contributing to SQLiteVecKit

Thanks for your interest! This is a small, focused package — the bar for
changes is correctness and simplicity, not feature count.

## Building and testing

The full gate (all four must pass before any PR):

```bash
swift build
swift build -c release   # release matters: it exercises the optimized NEON codegen
swift test               # full suite (Swift wrapper + C layer)
swift test -c release    # NEON-vs-scalar consistency gate
```

`swift build` also compiles everything under `Snippets/` — the code examples
embedded in the documentation — so an API change that breaks an example fails
the build. If you change a snippet, update the matching fenced code block in
the `.docc` articles (they mirror each other; the comment above each block
names its snippet file).

Documentation is validated the same way code is:

```bash
xcodebuild docbuild -scheme SQLiteVecKit \
    -destination 'generic/platform=macOS' \
    OTHER_DOCC_FLAGS='--warnings-as-errors'
```

A broken ``symbol`` link or malformed directive fails this build (and CI).

## Vendoring policy

`Sources/CSQLiteVec/sqlite-vec.c` and `sqlite-vec.h` are the **unmodified
upstream amalgamation** — never edit them. Any adaptation belongs in
`SQLiteVecShim.c` or `SQLiteVecBootstrap.c/.h`. The vendored bytes are
checksum-locked:

```bash
./scripts/vendor-sqlite-vec.sh verify   # runs in CI; opt-in pre-push hook:
git config core.hooksPath .githooks    # enables it locally
```

Upgrading sqlite-vec has its own checklist in [AGENTS.md](AGENTS.md)
("Upgrading sqlite-vec").

## Changing the API

- Design changes need a rationale entry in [DECISIONS.md](DECISIONS.md)
  (Context / Decision / Revisit-when). Read #1, #4, and #6 first — they
  explain why the API is shaped the way it is and what the version number
  promises.
- User-visible changes need a [CHANGELOG.md](CHANGELOG.md) entry.
- The semver policy (DECISIONS.md #4) is strict: breaking the Swift API or
  invalidating existing database files is a **major**-version event, and the
  vec0 table's column layout counts as public API (consumers write SQL
  against it).

## Tests

Swift Testing (`@Suite`/`@Test`), not XCTest. One suite per feature area;
wrapper tests open a fresh temporary SQLite file and delete it in a `defer`,
C-layer tests use `:memory:`. New behavior ships with tests — including the
failure paths (every `SQLiteError` case a change introduces should be
exercised).

## Code conventions

Swift 6 strict concurrency; identifiers and comments in English; comments
explain *why* (constraints, gotchas), not *what*. Match the style of the
surrounding files: value types live under `Sources/SQLiteVecStore/Types/`
(one file per type), the `VectorStore` actor and its `VectorStore+*.swift`
extensions under `Sources/SQLiteVecStore/Store/`.
