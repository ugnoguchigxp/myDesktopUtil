#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_PATH=$("${SCRIPT_DIR}/build-app.sh")

open "${APP_PATH}" --args "$@"
