#!/usr/bin/env bash
# Concatenates the src/ modules (in order) into the single-file install.sh
# release artifact. Use --check to verify install.sh is up to date, as CI does.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="${ROOT_DIR}/install.sh"
MODE="write"

MODULES=(
  "src/00-bootstrap.sh"
  "src/10-core.sh"
  "src/20-help-args.sh"
  "src/30-input-validation.sh"
  "src/40-preflight-runtime.sh"
  "src/50-network-vnc.sh"
  "src/60-backup-rollback.sh"
  "src/70-config-generation.sh"
  "src/80-state-verify-helpers.sh"
  "src/90-actions-main.sh"
)

if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ "${1:-}" != "" ]]; then
  printf 'Usage: %s [--check]\n' "$0" >&2
  exit 64
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

first=1
for module in "${MODULES[@]}"; do
  path="${ROOT_DIR}/${module}"
  if [[ ! -f "$path" ]]; then
    printf 'Missing release module: %s\n' "$module" >&2
    exit 1
  fi

  if (( first )); then
    first=0
  else
    printf '\n# ---- %s ----\n\n' "$module" >> "$tmp"
  fi
  cat "$path" >> "$tmp"
done

chmod 0755 "$tmp"
bash -n "$tmp"

if [[ "$MODE" == "check" ]]; then
  if ! cmp -s "$tmp" "$OUT_FILE"; then
    printf 'Generated install.sh is out of date. Run scripts/build-release.sh.\n' >&2
    exit 1
  fi
  exit 0
fi

mv "$tmp" "$OUT_FILE"
trap - EXIT

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=style "$OUT_FILE"
fi
