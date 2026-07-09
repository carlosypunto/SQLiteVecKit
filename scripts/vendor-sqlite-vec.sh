#!/usr/bin/env bash
#
# vendor-sqlite-vec.sh
#
# Reproducibly vendors the sqlite-vec amalgamation (sqlite-vec.c / sqlite-vec.h)
# plus its license files into this repository, pinned to a specific upstream
# release and verified by SHA-256.
#
# sqlite-vec.c / sqlite-vec.h are NOT plain committed files upstream -- only a
# sqlite-vec.h.tmpl template is committed to the source tree. The real,
# generated amalgamation only exists inside the GitHub Release asset tarball,
# so both files are fetched from there. LICENSE-MIT / LICENSE-APACHE ARE
# plain committed files in the source tree and are fetched via
# raw.githubusercontent.com instead.
#
# The "version pin" for vendored C source is the pair (UPSTREAM_REF + checksums.lock).
# CI runs this in verify mode; any drift from the locked bytes fails the build.
#
# Usage:
#   ./scripts/vendor-sqlite-vec.sh verify     # default; fails if vendored bytes != lock
#   ./scripts/vendor-sqlite-vec.sh update     # re-vendors from UPSTREAM_REF, rewrites lock
#
set -euo pipefail

# -- Pin here. Bump deliberately, review the diff, run `update`, commit the lock. --
UPSTREAM_REF="v0.1.9"                    # git tag of asg017/sqlite-vec
VERSION_NO_V="${UPSTREAM_REF#v}"         # release asset filenames drop the leading "v"
RAW="https://raw.githubusercontent.com/asg017/sqlite-vec/${UPSTREAM_REF}"
RELEASE_ASSET="https://github.com/asg017/sqlite-vec/releases/download/${UPSTREAM_REF}/sqlite-vec-${VERSION_NO_V}-amalgamation.tar.gz"

DEST="Sources/CSQLiteVec"
LOCK="${DEST}/checksums.lock"

SOURCE_FILES=(sqlite-vec.c sqlite-vec.h)
LICENSE_FILES=(LICENSE-MIT LICENSE-APACHE)

MODE="${1:-verify}"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

download_license() {
  local name="$1" out="$2"
  echo "  down ${name} @ ${UPSTREAM_REF} (source tree)"
  curl -fsSL "${RAW}/${name}" -o "${out}"
}

# sqlite-vec.c / sqlite-vec.h are generated files that ship only inside the
# release asset tarball (upstream commits a .tmpl for the header, not the
# generated header itself). Download the tarball once and copy both files
# out of it, wherever they land inside the archive.
fetch_amalgamation() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  echo "  down sqlite-vec-${VERSION_NO_V}-amalgamation.tar.gz @ ${UPSTREAM_REF}"
  curl -fsSL "${RELEASE_ASSET}" -o "${tmp}/amalgamation.tar.gz"
  tar -xzf "${tmp}/amalgamation.tar.gz" -C "${tmp}"
  for f in "${SOURCE_FILES[@]}"; do
    local found
    found="$(find "${tmp}" -name "${f}" -type f | head -n1)"
    [ -n "${found}" ] || { echo "ERROR: ${f} not found inside ${RELEASE_ASSET}" >&2; exit 1; }
    cp "${found}" "${DEST}/${f}"
  done
}

update() {
  echo "-> Vendoring sqlite-vec ${UPSTREAM_REF} into ${DEST}"
  mkdir -p "${DEST}"
  : > "${LOCK}"
  echo "# sqlite-vec vendored source -- pinned to ${UPSTREAM_REF}" >> "${LOCK}"
  echo "# Regenerate with: scripts/vendor-sqlite-vec.sh update" >> "${LOCK}"

  fetch_amalgamation
  for f in "${SOURCE_FILES[@]}"; do
    echo "$(sha "${DEST}/${f}")  ${f}" >> "${LOCK}"
  done

  # License files are a redistribution obligation, not versioned bytes -- and,
  # unlike the amalgamation, they ARE plain committed files upstream.
  for f in "${LICENSE_FILES[@]}"; do
    download_license "${f}" "${DEST}/${f}"
  done

  # Sanity: the release .h must carry the version define.
  if ! grep -q "SQLITE_VEC_VERSION" "${DEST}/sqlite-vec.h"; then
    echo "ERROR: sqlite-vec.h has no SQLITE_VEC_VERSION define -- is ${UPSTREAM_REF} a release tag?" >&2
    exit 1
  fi
  echo "OK: vendored and locked. Review the diff, then commit ${DEST}."
}

verify() {
  echo "-> Verifying vendored sqlite-vec against ${LOCK}"
  [ -f "${LOCK}" ] || { echo "ERROR: missing ${LOCK}. Run: $0 update" >&2; exit 1; }
  local failed=0
  while read -r want name; do
    case "${want}" in \#*|"") continue;; esac
    local path="${DEST}/${name}"
    [ -f "${path}" ] || { echo "MISSING: ${path}"; failed=1; continue; }
    local got; got="$(sha "${path}")"
    if [ "${got}" != "${want}" ]; then
      echo "DRIFT: ${name}"
      echo "    expected ${want}"
      echo "    actual   ${got}"
      failed=1
    else
      echo "OK: ${name}"
    fi
  done < "${LOCK}"

  # License files: existence-only check (see comment in update() re: not hash-locked).
  for f in "${LICENSE_FILES[@]}"; do
    if [ -f "${DEST}/${f}" ]; then
      echo "OK: ${f} present"
    else
      echo "MISSING: ${DEST}/${f}"
      failed=1
    fi
  done

  [ "${failed}" -eq 0 ] || { echo "ERROR: vendored source differs from pin ${UPSTREAM_REF}." >&2; exit 1; }
  echo "OK: vendored sqlite-vec matches pin ${UPSTREAM_REF}."
}

case "${MODE}" in
  update) update ;;
  verify) verify ;;
  *) echo "usage: $0 [verify|update]" >&2; exit 2 ;;
esac
