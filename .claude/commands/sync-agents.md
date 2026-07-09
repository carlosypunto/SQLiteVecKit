---
description: Review recent changes and propose minimal targeted updates to AGENTS.md
---

Bring `AGENTS.md` back in sync with the current state of the repository.

`AGENTS.md` is the canonical, tool-agnostic instruction file for all AI coding
agents. It is hand-curated: never regenerate it from scratch, never restructure
it, never summarize existing sections. Only make minimal, targeted edits.

## Procedure

1. Find when `AGENTS.md` was last modified:
   `git log -1 --format=%H -- AGENTS.md`
2. Review what changed in the repository since then:
   `git log --oneline <hash>..HEAD` and `git diff <hash>..HEAD --stat`, plus the
   current uncommitted diff. Focus on changes to the public API
   (`Sources/SQLiteVecStore/`), `Package.swift`, scripts, CI workflows, test
   structure, and `DECISIONS.md`.
3. For each change that contradicts or is missing from `AGENTS.md`, propose a
   minimal edit: update the affected sentence, table row, or code block in
   place. Do not touch unrelated sections.
4. If the vendored sqlite-vec version changed, verify the version string is
   consistent across: `AGENTS.md` (Overview), `THIRD-PARTY-NOTICES.md`
   ("Vendored version"), `README.md` (Third-Party Attribution),
   `CSQLiteVecTests` (`bundledVersionMatchesHeader`), and
   `SQLiteVecStoreTests` (`bundledVecVersionIsExposed`). Report any mismatch.
5. Show the proposed edits and apply them to `AGENTS.md` only.

## Hard rules

- Never modify `CLAUDE.md` — it is a bridge file that imports `AGENTS.md` and
  must stay as-is.
- Never run the built-in `/init` in this repository; it would overwrite the
  bridge file.
- If `AGENTS.md` is already in sync, say so and change nothing.
