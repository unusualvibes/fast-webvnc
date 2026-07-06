#!/usr/bin/env bash
# Builds the release tarball under dist/: rebuilds install.sh, then packages
# the docs, installer, scripts, and sources with a versioned prefix.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""
OUT_DIR="${ROOT_DIR}/dist"

usage() {
  printf 'Usage: %s [--version VERSION] [--output-dir DIR]\n' "$0" >&2
}

while (($#)); do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      OUT_DIR="$2"
      shift 2
      ;;
    --output-dir=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(awk -F= '$1 == "VERSION" {gsub(/"/, "", $2); print $2; exit}' "${ROOT_DIR}/src/00-bootstrap.sh")"
fi

if [[ -z "$VERSION" || "$VERSION" == *"/"* || "$VERSION" == *":"* || "$VERSION" =~ [[:space:]] ]]; then
  printf 'Invalid release version: %s\n' "${VERSION:-<empty>}" >&2
  exit 64
fi

"${ROOT_DIR}/scripts/build-release.sh"

mkdir -p "$OUT_DIR"

archive="${OUT_DIR}/fast-webvnc-${VERSION}.tar.gz"
prefix="fast-webvnc-${VERSION}/"
required_paths=(
  CHANGELOG.md
  LICENSE
  README.md
  install.sh
  scripts
  src
)
optional_paths=(
  CONTRIBUTING.md
)
release_paths=("${required_paths[@]}")

for path in "${required_paths[@]}"; do
  if [[ ! -e "${ROOT_DIR}/${path}" ]]; then
    printf 'Missing required release path: %s\n' "$path" >&2
    exit 1
  fi
done

for path in "${optional_paths[@]}"; do
  if [[ -e "${ROOT_DIR}/${path}" ]]; then
    release_paths+=("$path")
  fi
done

tar \
  --exclude=.git \
  --exclude=dist \
  --transform="s,^,${prefix}," \
  -czf "$archive" \
  -C "$ROOT_DIR" \
  "${release_paths[@]}"

printf 'Created %s\n' "$archive"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive"
fi
