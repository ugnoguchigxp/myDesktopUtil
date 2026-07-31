#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_PATH="${PROJECT_DIR}/dist/Desk Agent.app"
CONTENTS_PATH="${APP_PATH}/Contents"

cd "${PROJECT_DIR}"
swift build -c release >&2
BIN_PATH=$(swift build -c release --show-bin-path)

if [[ -e "${APP_PATH}" ]]; then
    rm -rf "${APP_PATH}"
fi

mkdir -p "${CONTENTS_PATH}/MacOS"
mkdir -p "${CONTENTS_PATH}/Resources"
cp "${BIN_PATH}/desk-agent" "${CONTENTS_PATH}/MacOS/desk-agent"
cp "${PROJECT_DIR}/packaging/Info.plist" "${CONTENTS_PATH}/Info.plist"
cp "${PROJECT_DIR}/packaging/AppIcon.icns" "${CONTENTS_PATH}/Resources/AppIcon.icns"
chmod 755 "${CONTENTS_PATH}/MacOS/desk-agent"

plutil -lint "${CONTENTS_PATH}/Info.plist" >&2

SIGNING_IDENTITY=${DESK_AGENT_SIGNING_IDENTITY:-}
LOCAL_SIGNING_IDENTITY="Desk Agent Local Code Signing"
if [[ -z "${SIGNING_IDENTITY}" ]] &&
    security find-identity -v -p codesigning |
        grep -F "\"${LOCAL_SIGNING_IDENTITY}\"" >/dev/null; then
    SIGNING_IDENTITY=${LOCAL_SIGNING_IDENTITY}
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
    SIGNING_IDENTITY=-
    echo \
        "warning: ad hoc signing does not preserve privacy permissions across builds" \
        >&2
    echo \
        "run scripts/install-local-signing-identity.sh before distributing locally" \
        >&2
fi

codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_PATH}" >&2
codesign --verify --deep --strict "${APP_PATH}" >&2

echo "${APP_PATH}"
