#!/usr/bin/env bash
set -euo pipefail

# Install nono binary for GitHub Actions (Linux x86_64 only for now)

NONO_VERSION="${NONO_VERSION:-latest}"
INSTALL_DIR="${RUNNER_TOOL_CACHE:-/tmp}/nono"
NONO_BIN="${INSTALL_DIR}/nono"

# Skip if already installed
if [[ -x "${NONO_BIN}" ]]; then
    echo "nono already installed at ${NONO_BIN}"
    "${NONO_BIN}" --version
    echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"
    exit 0
fi

mkdir -p "${INSTALL_DIR}"

# Determine download URL
REPO="always-further/nono"
if [[ "${NONO_VERSION}" == "latest" ]]; then
    DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/nono-x86_64-unknown-linux-gnu.tar.gz"
else
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${NONO_VERSION}/nono-x86_64-unknown-linux-gnu.tar.gz"
fi

echo "Downloading nono from ${DOWNLOAD_URL}"
curl -fsSL "${DOWNLOAD_URL}" -o "${INSTALL_DIR}/nono.tar.gz"

# Extract binary
tar -xzf "${INSTALL_DIR}/nono.tar.gz" -C "${INSTALL_DIR}"
rm "${INSTALL_DIR}/nono.tar.gz"
chmod +x "${NONO_BIN}"

# Verify
"${NONO_BIN}" --version

# Add to PATH for subsequent steps
echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"
echo "nono installed to ${INSTALL_DIR}"
