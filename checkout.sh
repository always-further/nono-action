#!/usr/bin/env bash
set -euo pipefail

# checkout.sh - Sandboxed git checkout via nono
#
# Replaces actions/checkout with a nono-sandboxed git clone.
# The GITHUB_TOKEN is injected via nono's credential proxy —
# never persisted in .git/config or the child's environment.
#
# Security advantages over actions/checkout:
#   - Token never touches disk (no .git/config credential storage)
#   - Clone runs inside Landlock sandbox (malicious .gitattributes / hooks contained)
#   - Network restricted to github.com only
#   - Token stripped from child environment

REPOSITORY="${NONO_ACTION_CHECKOUT_REPOSITORY:-${GITHUB_REPOSITORY}}"
REF="${NONO_ACTION_CHECKOUT_REF:-}"
FETCH_DEPTH="${NONO_ACTION_CHECKOUT_FETCH_DEPTH:-1}"
CHECKOUT_PATH="${NONO_ACTION_CHECKOUT_PATH:-${GITHUB_WORKSPACE}}"
TOKEN="${NONO_ACTION_CHECKOUT_TOKEN:-${GITHUB_TOKEN:-}}"

# --------------------------------------------------------------------------
# Resolve the ref to fetch
# --------------------------------------------------------------------------
if [[ -n "${REF}" ]]; then
    FETCH_REF="${REF}"
elif [[ -n "${GITHUB_REF:-}" ]]; then
    FETCH_REF="${GITHUB_REF}"
else
    FETCH_REF="HEAD"
fi

# --------------------------------------------------------------------------
# Credential setup: inject GITHUB_TOKEN via nono's proxy for github.com
# --------------------------------------------------------------------------
CRED_DIR="$(mktemp -d /tmp/nono-checkout-creds.XXXXXX)"
chmod 700 "${CRED_DIR}"

cleanup() {
    if [[ -d "${CRED_DIR}" ]]; then
        find "${CRED_DIR}" -type f -exec shred -u {} \; 2>/dev/null || rm -rf "${CRED_DIR}"
    fi
}
trap cleanup EXIT

NONO_ARGS=(--allow-cwd --no-rollback --no-diagnostics)
PROFILE=""

if [[ -n "${TOKEN}" ]]; then
    # Git over HTTPS uses Basic auth: base64("x-access-token:TOKEN")
    CRED_FILE="${CRED_DIR}/github_token"
    printf '%s' "$(echo -n "x-access-token:${TOKEN}" | base64 -w0)" > "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"

    # Mask the token in logs
    echo "::add-mask::${TOKEN}"

    # Generate nono profile for credential injection
    PROFILE="${CRED_DIR}/checkout-profile.json"
    cat > "${PROFILE}" <<ENDJSON
{
  "extends": "default",
  "meta": {
    "name": "nono-action-checkout",
    "version": "1.0.0"
  },
  "network": {
    "proxy_credentials": ["github_token"],
    "custom_credentials": {
      "github_token": {
        "upstream": "https://github.com",
        "credential_key": "file://${CRED_FILE}",
        "inject_mode": "header",
        "inject_header": "Authorization",
        "credential_format": "Basic {}"
      }
    }
  }
}
ENDJSON

    NONO_ARGS+=(--profile "${PROFILE}")
    NONO_ARGS+=(--allow-domain "github.com")
else
    # No token — public repo clone, just need network access to github.com
    NONO_ARGS+=(--allow-domain "github.com")
fi

# Write access to the checkout directory
NONO_ARGS+=(--write "${CHECKOUT_PATH}")

# --------------------------------------------------------------------------
# Build the git commands to run inside the sandbox
# --------------------------------------------------------------------------
DEPTH_ARG=""
if [[ "${FETCH_DEPTH}" != "0" ]]; then
    DEPTH_ARG="--depth=${FETCH_DEPTH}"
fi

GIT_COMMANDS="$(cat <<ENDSCRIPT
set -euo pipefail

# Initialize repository
if [[ ! -d "${CHECKOUT_PATH}/.git" ]]; then
    git init "${CHECKOUT_PATH}"
fi
cd "${CHECKOUT_PATH}"

# Configure git (no credential persistence — the proxy handles auth)
git config --local gc.auto 0
git config --local advice.detachedHead false

# Add remote
git remote add origin "https://github.com/${REPOSITORY}.git" 2>/dev/null || \
    git remote set-url origin "https://github.com/${REPOSITORY}.git"

# Fetch the requested ref
echo "Fetching ref: ${FETCH_REF}"
git fetch ${DEPTH_ARG} origin "${FETCH_REF}"

# Checkout
git checkout --progress --force FETCH_HEAD

echo "Checked out ${REPOSITORY} at ref ${FETCH_REF}"
git log --oneline -1
ENDSCRIPT
)"

# --------------------------------------------------------------------------
# Execute sandboxed checkout
# --------------------------------------------------------------------------
echo "::group::nono sandboxed checkout"
echo "  repository:  ${REPOSITORY}"
echo "  ref:         ${FETCH_REF}"
echo "  path:        ${CHECKOUT_PATH}"
echo "  depth:       ${FETCH_DEPTH}"
echo "  auth:        $(if [[ -n "${TOKEN}" ]]; then echo "token (via proxy)"; else echo "none (public)"; fi)"
echo "::endgroup::"

# Strip secrets and action metadata from the environment
unset NONO_ACTION_CHECKOUT_TOKEN 2>/dev/null || true
unset NONO_ACTION_CHECKOUT_REPOSITORY 2>/dev/null || true
unset NONO_ACTION_CHECKOUT_REF 2>/dev/null || true
unset NONO_ACTION_CHECKOUT_FETCH_DEPTH 2>/dev/null || true
unset NONO_ACTION_CHECKOUT_PATH 2>/dev/null || true
unset GITHUB_TOKEN 2>/dev/null || true

nono run \
    "${NONO_ARGS[@]}" \
    -- bash -c "${GIT_COMMANDS}"
