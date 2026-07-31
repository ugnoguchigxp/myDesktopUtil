#!/bin/zsh
set -euo pipefail

IDENTITY_NAME="Desk Agent Local Code Signing"

if security find-identity -v -p codesigning |
    grep -F "\"${IDENTITY_NAME}\"" >/dev/null; then
    echo "${IDENTITY_NAME} is already installed"
    exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl command was not found" >&2
    exit 1
fi

LOGIN_KEYCHAIN=$(
    security login-keychain |
        sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
)
if [[ -z "${LOGIN_KEYCHAIN}" || ! -f "${LOGIN_KEYCHAIN}" ]]; then
    echo "login keychain was not found" >&2
    exit 1
fi

if security find-certificate \
    -c "${IDENTITY_NAME}" \
    "${LOGIN_KEYCHAIN}" \
    >/dev/null 2>&1; then
    echo \
        "${IDENTITY_NAME} exists but is not a usable code-signing identity" \
        >&2
    exit 1
fi

SIGNING_TEMP_DIR=$(mktemp -d "/tmp/desk-agent-signing.XXXXXX")
trap 'rm -rf -- "${SIGNING_TEMP_DIR}"' EXIT

PRIVATE_KEY="${SIGNING_TEMP_DIR}/private-key.pem"
CERTIFICATE="${SIGNING_TEMP_DIR}/certificate.pem"
IDENTITY_ARCHIVE="${SIGNING_TEMP_DIR}/identity.p12"
ARCHIVE_PASSWORD=$(openssl rand -hex 32)

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -nodes \
    -keyout "${PRIVATE_KEY}" \
    -out "${CERTIFICATE}" \
    -subj "/CN=${IDENTITY_NAME}/O=Desk Agent Local Development" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    >/dev/null 2>&1

openssl pkcs12 \
    -export \
    -legacy \
    -out "${IDENTITY_ARCHIVE}" \
    -inkey "${PRIVATE_KEY}" \
    -in "${CERTIFICATE}" \
    -name "${IDENTITY_NAME}" \
    -passout "pass:${ARCHIVE_PASSWORD}" \
    >/dev/null 2>&1

security import "${IDENTITY_ARCHIVE}" \
    -k "${LOGIN_KEYCHAIN}" \
    -P "${ARCHIVE_PASSWORD}" \
    -x \
    -T /usr/bin/codesign \
    >/dev/null
if ! security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "${LOGIN_KEYCHAIN}" \
    "${CERTIFICATE}"; then
    security delete-identity \
        -c "${IDENTITY_NAME}" \
        "${LOGIN_KEYCHAIN}" \
        >/dev/null 2>&1 ||
        true
    echo "code-signing certificate trust could not be configured" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning |
    grep -F "\"${IDENTITY_NAME}\"" >/dev/null; then
    security delete-identity \
        -c "${IDENTITY_NAME}" \
        "${LOGIN_KEYCHAIN}" \
        >/dev/null 2>&1 ||
        true
    echo "code-signing identity installation failed" >&2
    exit 1
fi

echo "${IDENTITY_NAME} installed"
