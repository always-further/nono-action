# nono-action

GitHub Action that wraps CI commands with [nono](https://github.com/always-further/nono) OS-kernel sandboxing.

**What it does:**
- Sandboxed git checkout — replaces `actions/checkout` with a kernel-sandboxed clone
- Restricts filesystem access per step (read/write allowlists)
- Blocks or allowlists network by domain
- Strips secrets from the child's environment and injects them via HTTP proxy — only to approved hosts
- Prevents fork PR secret exfiltration at the kernel level

## Usage

```yaml
# Sandboxed checkout + sandboxed test run — no actions/checkout needed
- uses: always-further/nono-action@v1
  with:
    checkout: true
    checkout-ref: ${{ github.event.pull_request.head.sha }}
    run: npm test
    fs-read: "./src, ./tests, ./node_modules"
    fs-write: "./coverage"
    network: blocked
```

## Sandboxed checkout

Drop-in replacement for `actions/checkout` that clones inside a nono sandbox.

**Why this matters:**

`actions/checkout` persists your `GITHUB_TOKEN` in `.git/config` — any code that runs afterward can read it. It also runs unsandboxed, so malicious `.gitattributes`, git hooks, and smudge filters in a fork's code execute with full access.

nono-action's checkout:
- Injects the token via nono's HTTP proxy — **never written to disk**
- Runs `git clone` inside a Landlock sandbox — malicious git hooks can't escape
- Restricts network to `github.com` only during fetch
- Strips the token from the environment before any user code runs

```yaml
# Replace actions/checkout entirely
- uses: always-further/nono-action@v1
  with:
    checkout: true
    run: npm test
    fs-read: "."
    network: blocked
```

For `pull_request_target` workflows (fork PRs with secrets):

```yaml
- uses: always-further/nono-action@v1
  with:
    checkout: true
    checkout-ref: ${{ github.event.pull_request.head.sha }}
    run: npm test
    fs-read: "./src, ./tests, ./node_modules"
    network: blocked
```

### Checkout inputs

| Input | Default | Description |
|-------|---------|-------------|
| `checkout` | `""` | Set to `"true"` to enable sandboxed checkout |
| `checkout-repository` | current repo | Repository in `owner/repo` format |
| `checkout-ref` | `GITHUB_REF` | Git ref to checkout (branch, tag, or SHA) |
| `checkout-fetch-depth` | `1` | Number of commits to fetch (`0` = full history) |
| `checkout-path` | `GITHUB_WORKSPACE` | Directory to checkout into |
| `checkout-token` | `github.token` | Auth token — injected via proxy, never on disk |

## Sandbox inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `run` | No | — | Command to execute inside the sandbox |
| `fs-read` | No | workspace | Comma-separated paths for read access |
| `fs-write` | No | none | Comma-separated paths for write access |
| `network` | No | `blocked` | `blocked` or comma-separated domain allowlist |
| `credentials` | No | none | Newline-separated `SECRET:host:mode` mappings |
| `profile` | No | none | Path to a nono profile JSON (overrides other inputs) |
| `nono-version` | No | `latest` | nono release version |

## Credential proxy

Secrets are never exposed to the sandboxed process:

```yaml
- uses: always-further/nono-action@v1
  with:
    run: ./deploy.sh
    fs-read: "./dist"
    network: "api.fly.io"
    credentials: |
      DEPLOY_TOKEN:api.fly.io:header
  env:
    DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

**What happens:**
1. `run.sh` reads `$DEPLOY_TOKEN` from the environment
2. Writes it to a tmpfile in `/tmp/nono-creds.XXXXXX/` (outside the sandbox)
3. Unsets `$DEPLOY_TOKEN` from the environment
4. Generates a nono profile pointing to `file:///tmp/nono-creds.XXXXXX/cred_0`
5. nono's proxy injects the token into `Authorization: Bearer ...` headers — **only** for requests to `api.fly.io`
6. The child process sees no secret in env, can't read the tmpfile, can't reach any other host
7. On exit, tmpfiles are shredded

## Fork PR protection

The classic attack: attacker forks your repo, opens a PR, workflow runs with your secrets.

With nono-action, even if `pull_request_target` exposes secrets:
- The secret is stripped from env before the fork's code runs
- Network is blocked or limited to declared hosts
- Filesystem writes are restricted to declared paths
- The fork can't modify the action (resolved from base branch, pinned by SHA)

## How it works

```
GitHub Actions runtime
  └─ injects $SECRET into env

  ── Step 1: Sandboxed checkout ──
  checkout.sh (our code, not the fork's)
    ├─ writes GITHUB_TOKEN to tmpfile (outside sandbox)
    ├─ generates nono profile for credential proxy
    └─ nono run --write $WORKSPACE --allow-domain github.com ...
        ├─ Landlock: only github.com reachable
        ├─ Proxy: injects token as Basic auth header
        ├─ git clone + checkout runs here
        └─ malicious .gitattributes / hooks contained by sandbox

  ── Step 2: Sandboxed command ──
  run.sh (our code, not the fork's)
    ├─ reads $SECRET, writes to tmpfile
    ├─ unsets $SECRET from env
    └─ nono run --read ./src --write ./dist --allow-domain api.fly.io ...
        ├─ Landlock: kernel denies fs access outside declared paths
        ├─ Landlock: kernel denies network except proxy port
        ├─ Proxy: injects credential only to api.fly.io
        └─ child process runs here (fork's code) — nothing to steal
```

## Examples

See [examples/ci-workflow.yml](examples/ci-workflow.yml) for a complete workflow.
