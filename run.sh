#!/usr/bin/env bash
set -euo pipefail

# run.sh - Translate GitHub Action inputs into nono CLI flags
#
# Secret handling strategy:
#   1. Read each credential from env (GitHub injected it)
#   2. Write the secret value to a tmpfile outside the child's sandbox
#   3. Generate a nono profile JSON referencing file:// URIs
#   4. Unset the secret env var so the child never sees it
#   5. nono proxy reads credentials from the tmpfiles and injects into HTTP requests
#   6. The child process has no access to the tmpfiles (outside its fs sandbox)

COMMAND="${NONO_ACTION_COMMAND}"
FS_READ="${NONO_ACTION_FS_READ:-}"
FS_WRITE="${NONO_ACTION_FS_WRITE:-}"
NETWORK="${NONO_ACTION_NETWORK:-blocked}"
CREDENTIALS="${NONO_ACTION_CREDENTIALS:-}"
PROFILE="${NONO_ACTION_PROFILE:-}"

# Secure tmpdir for credential files — outside the child's sandbox
CRED_DIR="$(mktemp -d /tmp/nono-creds.XXXXXX)"
chmod 700 "${CRED_DIR}"

cleanup() {
    # Securely remove credential files
    if [[ -d "${CRED_DIR}" ]]; then
        find "${CRED_DIR}" -type f -exec shred -u {} \; 2>/dev/null || rm -rf "${CRED_DIR}"
    fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# If a profile is provided, use it directly (power-user mode)
# --------------------------------------------------------------------------
if [[ -n "${PROFILE}" ]]; then
    exec nono run --profile "${PROFILE}" --no-rollback --no-diagnostics -- bash -c "${COMMAND}"
fi

# --------------------------------------------------------------------------
# Build nono CLI flags from action inputs
# --------------------------------------------------------------------------
NONO_ARGS=()

# -- Filesystem: read paths --
if [[ -n "${FS_READ}" ]]; then
    IFS=',' read -ra READ_PATHS <<< "${FS_READ}"
    for p in "${READ_PATHS[@]}"; do
        trimmed="$(echo "${p}" | xargs)"
        if [[ -n "${trimmed}" ]]; then
            NONO_ARGS+=(--read "${trimmed}")
        fi
    done
fi

# -- Filesystem: write paths --
if [[ -n "${FS_WRITE}" ]]; then
    IFS=',' read -ra WRITE_PATHS <<< "${FS_WRITE}"
    for p in "${WRITE_PATHS[@]}"; do
        trimmed="$(echo "${p}" | xargs)"
        if [[ -n "${trimmed}" ]]; then
            NONO_ARGS+=(--write "${trimmed}")
        fi
    done
fi

# Always allow read to workspace (GITHUB_WORKSPACE) if no explicit fs-read
if [[ -z "${FS_READ}" && -n "${GITHUB_WORKSPACE:-}" ]]; then
    NONO_ARGS+=(--read "${GITHUB_WORKSPACE}")
fi

# --------------------------------------------------------------------------
# Network policy
# --------------------------------------------------------------------------
HAS_CREDENTIALS=false

if [[ -n "${CREDENTIALS}" ]]; then
    HAS_CREDENTIALS=true
fi

if [[ "${NETWORK}" == "blocked" && "${HAS_CREDENTIALS}" == "false" ]]; then
    # Simple case: block all network
    NONO_ARGS+=(--block-net)
elif [[ "${NETWORK}" == "blocked" && "${HAS_CREDENTIALS}" == "true" ]]; then
    # Credentials need proxy, but no additional hosts allowed
    # allow-domain will be added per credential below
    :
else
    # Domain allowlist
    IFS=',' read -ra DOMAINS <<< "${NETWORK}"
    for d in "${DOMAINS[@]}"; do
        trimmed="$(echo "${d}" | xargs)"
        if [[ -n "${trimmed}" ]]; then
            NONO_ARGS+=(--allow-domain "${trimmed}")
        fi
    done
fi

# --------------------------------------------------------------------------
# Credential handling: strip from env, write to tmpfiles, build proxy config
# --------------------------------------------------------------------------
# Format per line: SECRET_ENV_NAME:target_host:inject_mode
#
# inject_mode is optional, defaults to "header" (Authorization: Bearer {value})
#
# Example:
#   DEPLOY_TOKEN:api.fly.io:header
#   NPM_TOKEN:registry.npmjs.org:header

GENERATED_PROFILE=""

if [[ -n "${CREDENTIALS}" ]]; then
    # We need a generated profile for custom_credentials
    CRED_CONFIGS=""
    CRED_NAMES=""
    ALLOW_HOSTS=""
    CRED_INDEX=0

    while IFS= read -r line; do
        # Skip empty lines
        line="$(echo "${line}" | xargs)"
        [[ -z "${line}" ]] && continue

        # Parse: SECRET_NAME:host:inject_mode
        IFS=':' read -r secret_env target_host inject_mode <<< "${line}"
        inject_mode="${inject_mode:-header}"
        cred_name="cred_${CRED_INDEX}"

        # Read the secret value from the environment
        secret_value="${!secret_env:-}"
        if [[ -z "${secret_value}" ]]; then
            echo "::warning::Credential ${secret_env} is not set in the environment, skipping"
            continue
        fi

        # Write secret to a tmpfile (outside child's sandbox)
        cred_file="${CRED_DIR}/${cred_name}"
        printf '%s' "${secret_value}" > "${cred_file}"
        chmod 600 "${cred_file}"

        # Unset the secret from the environment so the child never sees it
        unset "${secret_env}"
        # Also mask it in GitHub Actions logs
        echo "::add-mask::${secret_value}"

        # Build JSON fragment for this credential
        if [[ -n "${CRED_CONFIGS}" ]]; then
            CRED_CONFIGS+=","
        fi
        CRED_CONFIGS+="$(cat <<ENDJSON
    "${cred_name}": {
      "upstream": "https://${target_host}",
      "credential_key": "file://${cred_file}",
      "inject_mode": "${inject_mode}",
      "inject_header": "Authorization",
      "credential_format": "Bearer {}",
      "env_var": "NONO_CRED_${CRED_INDEX}"
    }
ENDJSON
)"
        if [[ -n "${CRED_NAMES}" ]]; then
            CRED_NAMES+=","
        fi
        CRED_NAMES+="\"${cred_name}\""

        # Ensure the credential's target host is in the allowlist
        NONO_ARGS+=(--allow-domain "${target_host}")

        CRED_INDEX=$((CRED_INDEX + 1))
    done <<< "${CREDENTIALS}"

    if [[ ${CRED_INDEX} -gt 0 ]]; then
        # Generate a temporary profile with custom credentials
        GENERATED_PROFILE="${CRED_DIR}/profile.json"
        cat > "${GENERATED_PROFILE}" <<ENDJSON
{
  "extends": "default",
  "meta": {
    "name": "nono-action-generated",
    "version": "1.0.0"
  },
  "network": {
    "proxy_credentials": [${CRED_NAMES}],
    "custom_credentials": {
${CRED_CONFIGS}
    }
  }
}
ENDJSON
        NONO_ARGS+=(--profile "${GENERATED_PROFILE}")
    fi
fi

# --------------------------------------------------------------------------
# Execute
# --------------------------------------------------------------------------
echo "::group::nono sandbox configuration"
echo "  filesystem read:  ${FS_READ:-<workspace>}"
echo "  filesystem write: ${FS_WRITE:-<none>}"
echo "  network:          ${NETWORK}"
echo "  credentials:      $(echo "${CREDENTIALS}" | grep -c ':' || echo 0) configured"
echo "  nono args:        ${NONO_ARGS[*]:-<none>}"
echo "::endgroup::"

# Strip action metadata env vars — they contain credential mappings,
# the command string, and other internals the child should not see.
unset NONO_ACTION_COMMAND
unset NONO_ACTION_FS_READ
unset NONO_ACTION_FS_WRITE
unset NONO_ACTION_NETWORK
unset NONO_ACTION_CREDENTIALS
unset NONO_ACTION_PROFILE

exec nono run \
    --allow-cwd \
    --no-rollback \
    --no-diagnostics \
    "${NONO_ARGS[@]}" \
    -- bash -c "${COMMAND}"
