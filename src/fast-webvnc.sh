#!/usr/bin/env bash
# Development entry point: sources the modules directly so you can run the
# installer without rebuilding install.sh. Try: src/fast-webvnc.sh help
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/00-bootstrap.sh
source "${SRC_DIR}/00-bootstrap.sh"
# shellcheck source=src/10-core.sh
source "${SRC_DIR}/10-core.sh"
# shellcheck source=src/20-help-args.sh
source "${SRC_DIR}/20-help-args.sh"
# shellcheck source=src/30-input-validation.sh
source "${SRC_DIR}/30-input-validation.sh"
# shellcheck source=src/40-preflight-runtime.sh
source "${SRC_DIR}/40-preflight-runtime.sh"
# shellcheck source=src/50-network-vnc.sh
source "${SRC_DIR}/50-network-vnc.sh"
# shellcheck source=src/60-backup-rollback.sh
source "${SRC_DIR}/60-backup-rollback.sh"
# shellcheck source=src/70-config-generation.sh
source "${SRC_DIR}/70-config-generation.sh"
# shellcheck source=src/80-state-verify-helpers.sh
source "${SRC_DIR}/80-state-verify-helpers.sh"
# shellcheck source=src/90-actions-main.sh
source "${SRC_DIR}/90-actions-main.sh"
