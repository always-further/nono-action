# nono-action

GitHub Action that wraps CI commands with [nono](https://github.com/always-further/nono) OS-kernel sandboxing.

**What it does:**
- Restricts filesystem access per step (read/write allowlists)
- Blocks or allowlists network by domain
- Strips secrets from the child's environment and injects them via HTTP proxy — only to approved hosts
- Prevents fork PR secret exfiltration at the kernel level

## Usage

```yaml
- uses: nono-sandbox/action@v1
  with:
    run: npm test
    fs-read: "./src, ./tests, ./node_modules"
    fs-write: "./coverage"
    network: blocked
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `run` | Yes | — | Command to execute inside the sandbox |
| `fs-read` | No | workspace | Comma-separated paths for read access |
| `fs-write` | No | none | Comma-separated paths for write access |
| `network` | No | `blocked` | `blocked` or comma-separated domain allowlist |
| `credentials` | No | none | Newline-separated `SECRET:host:mode` mappings |
| `profile` | No | none | Path to a nono profile JSON (overrides other inputs) |
| `nono-version` | No | `latest` | nono release version |

## Credential proxy

Secrets are never exposed to the sandboxed process:

```yaml
- uses: nono-sandbox/action@v1
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
    └─ run.sh (action wrapper — our code, not the fork's)
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
