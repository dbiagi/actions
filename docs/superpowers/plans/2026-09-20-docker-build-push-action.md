# docker-build-push Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a registry-agnostic GitHub composite action that builds a Dockerfile and publishes the image to any container registry, as the first action in a folder-per-action monorepo.

**Architecture:** A composite action (`docker-build-push/action.yml`) orchestrates the official `docker/*` actions — `setup-qemu-action`, `setup-buildx-action`, `login-action`, `metadata-action`, `build-push-action`. All shell logic lives in standalone, unit-tested scripts under `docker-build-push/scripts/`, so `action.yml` is pure wiring and every line of bash is shellcheckable and testable without a runner.

**Tech Stack:** GitHub Actions composite action (YAML), Bash 4+, `docker/*` actions (setup-qemu v4, setup-buildx v4, login v4, metadata v6, build-push v7), actionlint, yamllint, shellcheck.

**Spec:** `docs/superpowers/specs/2026-09-20-docker-build-push-action-design.md`

## Global Constraints

- **All boolean input comparisons are string comparisons.** Composite action inputs are always strings; `if: inputs.push` is truthy for the literal `"false"`. Always write `inputs.push == 'true'`.
- **`provenance: false`** on `build-push-action`. buildx attaches provenance attestations by default, which Docker Hub renders as phantom `unknown/unknown` architecture rows.
- **Every third-party action is pinned to a full commit SHA** with a trailing `# vX.Y.Z` comment. Never pin to a tag.
- **CI is lint-only** (actionlint + yamllint + shellcheck + the bash unit tests). No workflow in this repo pushes an image to any registry.
- **`image` never includes the registry host.** The host goes in `registry`; the full ref is `<registry>/<image>`.
- **Every action folder has a `README.md`** with an inputs table and usage examples and nothing else, per `docs/knowledge/rules.md`.
- **Default platform is `linux/amd64`.** QEMU is only set up when `platforms` differs from that.

## Deviations from the spec, recorded

### 1. Shell logic lives in scripts, not inline

The spec describes validation as "a bash step". This plan puts that bash in
`docker-build-push/scripts/validate.sh` rather than inline in `action.yml`, and
does the same for the build-configuration logic. Same behavior, same step flow;
the reason is that inline `run:` blocks inside a composite `action.yml` are not
reachable by shellcheck and cannot be unit-tested, while standalone scripts are
both. This also means the lint-only CI decision gains real unit tests at zero
registry cost — the bash tests need no network, no Docker daemon and no
credentials. The spec's intent (fail fast, before expensive setup, with a
message naming the offending input) is unchanged.

### 2. `latest` uses metadata-action's `latest=auto` plus `{{is_default_branch}}`
The spec says `latest` is configured with `flavor: latest=false` plus a
`type=raw` entry, "rather than left to `latest=auto`". This plan does the
opposite: it keeps the default `latest=auto` (stable semver tags) and adds
`type=raw,value=latest,enable={{is_default_branch}}` (default-branch pushes).
Resulting behavior is the same as the spec's tag table. Two reasons: the
explicit form needs a 165-character `${{ }}` expression that fails yamllint
and cannot be wrapped or annotated inside a block scalar; and the natural
`startsWith(github.ref, 'refs/tags/v')` condition would also tag `latest` on
pre-releases such as `v1.2.3-rc1`, which `latest=auto` correctly skips. The spec
is updated to match.

### 3. Login condition also requires credentials for registry cache
The spec's condition `login == 'true' && (push == 'true' || cache == 'registry')`
failed for `push: false` with `cache: registry` and no credentials: validation
passes (credentials are only required when pushing), but the login step ran with
empty values and `docker/login-action` errored. The condition is now
`login == 'true' && (push == 'true' || (cache == 'registry' && username != ''))`.
`resolve-config.sh` already drops `cache-to` when not pushing, so only a private
cache read could need a login, and only when credentials were supplied. The spec
is updated to match.

---

### Task 1: Repo scaffolding and lint CI

**Files:**
- Create: `.yamllint.yml`
- Create: `.github/workflows/lint.yml`
- Create: `.github/dependabot.yml`
- Create: `README.md`
- Create: `CHANGELOG.md`
- Create: `LICENSE`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a working `bash docker-build-push/test/run.sh` entry point referenced by `lint.yml` (the script itself is created in Task 2; `lint.yml` is written to call it now and will fail until then, which is expected and resolved in Task 2).

- [ ] **Step 1: Install yamllint locally**

`shellcheck`, `gh` and `docker` are already on this machine; `yamllint` is not.

```bash
pipx install yamllint || python3 -m pip install --user yamllint
yamllint --version
```

- [ ] **Step 2: Write the yamllint config**

Create `.yamllint.yml`:

```yaml
---
extends: default

rules:
  line-length:
    max: 120
  # GitHub workflows use `on:` as a key, which yamllint's truthy rule
  # otherwise flags as a boolean-looking key.
  truthy:
    check-keys: false
  document-start: disable
  comments:
    min-spaces-from-content: 1
```

- [ ] **Step 3: Verify yamllint rejects bad YAML and accepts the config itself**

```bash
printf 'a: 1\nb:   2\n' > /tmp/bad.yml
yamllint -c .yamllint.yml /tmp/bad.yml
```

Expected: FAIL, reporting `too many spaces after colon`. Then:

```bash
yamllint -c .yamllint.yml .yamllint.yml && echo "config lints clean"
rm /tmp/bad.yml
```

Expected: PASS.

- [ ] **Step 4: Note the pinned versions**

Resolved against the GitHub API on 2026-09-20 and already filled in below, so
nothing needs looking up: `actions/checkout` v7.0.1 and `actionlint` 1.7.12.
Dependabot (Step 6) keeps the SHAs current from here on.

- [ ] **Step 5: Write the lint workflow**

Create `.github/workflows/lint.yml`:

```yaml
---
name: Lint

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: yamllint
        run: |
          pipx install yamllint
          yamllint -c .yamllint.yml .

      # actionlint validates workflow files. It does not validate a composite
      # action.yml, which is why Task 6 keeps a manual smoke test as the gate
      # before tagging a release.
      - name: actionlint
        uses: docker://rhysd/actionlint:1.7.12
        with:
          args: -color

      - name: shellcheck
        run: shellcheck docker-build-push/scripts/*.sh docker-build-push/test/*.sh

      - name: bash unit tests
        run: bash docker-build-push/test/run.sh
```

- [ ] **Step 6: Write the Dependabot config**

The `github-actions` ecosystem only scans directories named explicitly, so the
action's own `action.yml` needs its own entry.

Create `.github/dependabot.yml`:

```yaml
---
version: 2

updates:
  # Workflows in .github/workflows
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: weekly

  # The composite action's own pinned docker/* dependencies
  - package-ecosystem: github-actions
    directory: "/docker-build-push"
    schedule:
      interval: weekly
```

- [ ] **Step 7: Write the root README index**

Per `docs/knowledge/rules.md` the root README is an index only — no per-action
detail.

Create `README.md`:

````markdown
# actions

Custom GitHub Actions for my homelab. One folder per action.

| Action | Description |
|---|---|
| [`docker-build-push`](docker-build-push/) | Build a Dockerfile and publish it to any container registry. |

## Versioning

Repo-wide semver. Pin the floating major tag:

```yaml
- uses: dbiagi/actions/docker-build-push@v1
```

Tagging `vX.Y.Z` moves the `vX` tag to the same commit.

## Conventions

See [`docs/knowledge/rules.md`](docs/knowledge/rules.md).
````

Note: the three lines above marked with a zero-width-prefixed backtick fence are
a literal nested code block — write them as plain triple backticks in the file.

- [ ] **Step 8: Write CHANGELOG and LICENSE**

Create `CHANGELOG.md`:

````markdown
# Changelog

All notable changes to the actions in this repo.

The version is repo-wide: a release moves every action's floating major tag,
so an entry here names the action it affects.

## [Unreleased]

### Added
- `docker-build-push`: build a Dockerfile and publish it to any registry.
````

Create `LICENSE` — MIT, copyright `2026 Diego de Biagi`. Use the standard MIT
text verbatim from https://opensource.org/license/mit.

- [ ] **Step 9: Run the linters locally**

```bash
yamllint -c .yamllint.yml .
```

Expected: PASS (no output). `shellcheck` and the unit tests have nothing to run
against yet; they arrive in Task 2.

- [ ] **Step 10: Commit**

```bash
git add .yamllint.yml .github README.md CHANGELOG.md LICENSE
git commit -m "chore: repo scaffolding, lint CI and dependabot config"
```

---

### Task 2: Input validation script

Fails fast, before QEMU and buildx setup cost 10-20 seconds, with a message
naming the offending input.

**Files:**
- Create: `docker-build-push/scripts/validate.sh`
- Create: `docker-build-push/test/validate_test.sh`
- Create: `docker-build-push/test/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/validate.sh`, invoked as `bash "$GITHUB_ACTION_PATH/scripts/validate.sh"` with these environment variables set by `action.yml` in Task 4: `INPUT_IMAGE`, `INPUT_REGISTRY`, `INPUT_PUSH`, `INPUT_LOGIN`, `INPUT_USERNAME`, `INPUT_PASSWORD`, `INPUT_CACHE`. Exits 0 on valid input, exits 1 having written `::error::<message>` to stderr otherwise. Also produces `test/run.sh`, the entry point `lint.yml` calls.

- [ ] **Step 1: Write the failing test**

Create `docker-build-push/test/validate_test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for scripts/validate.sh. No network, no Docker, no credentials.
set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VALIDATE="$TEST_DIR/../scripts/validate.sh"

failures=0

# Runs validate.sh with a valid baseline environment; arguments are
# KEY=VALUE overrides applied after the baseline, so later wins.
validate_with() {
  env \
    INPUT_IMAGE=dbiagi/myapp \
    INPUT_REGISTRY=docker.io \
    INPUT_PUSH=true \
    INPUT_LOGIN=true \
    INPUT_USERNAME=someuser \
    INPUT_PASSWORD=sometoken \
    INPUT_CACHE=gha \
    "$@" \
    bash "$VALIDATE" 2>&1
}

assert_pass() {
  local desc=$1
  shift
  local output
  if output=$(validate_with "$@"); then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected exit 0)"
    echo "       output: $output"
    failures=$((failures + 1))
  fi
}

assert_fail() {
  local desc=$1 pattern=$2
  shift 2
  local output
  if output=$(validate_with "$@"); then
    echo "FAIL - $desc (expected non-zero exit, got 0)"
    failures=$((failures + 1))
  elif [[ "$output" != *"$pattern"* ]]; then
    echo "FAIL - $desc (message did not contain '$pattern')"
    echo "       output: $output"
    failures=$((failures + 1))
  else
    echo "ok   - $desc"
  fi
}

assert_pass "valid Docker Hub configuration"
assert_pass "push disabled needs no credentials" \
  INPUT_PUSH=false INPUT_USERNAME= INPUT_PASSWORD=
assert_pass "login disabled needs no credentials" \
  INPUT_LOGIN=false INPUT_USERNAME= INPUT_PASSWORD=
assert_pass "single-segment image is allowed" INPUT_IMAGE=myapp
assert_pass "registry cache backend is allowed" INPUT_CACHE=registry
assert_pass "cache can be disabled" INPUT_CACHE=none

assert_fail "image carrying a registry host is rejected" "must not include the registry host" \
  INPUT_IMAGE=ghcr.io/dbiagi/myapp
assert_fail "image carrying a host with a port is rejected" "must not include the registry host" \
  INPUT_IMAGE=localhost:5000/myapp
assert_fail "empty image is rejected" "'image' is required" INPUT_IMAGE=
assert_fail "missing username is rejected" "'username' is required" INPUT_USERNAME=
assert_fail "missing password is rejected" "'password' is required" INPUT_PASSWORD=
assert_fail "missing password mentions the fork PR workaround" "push: false" INPUT_PASSWORD=
assert_fail "unknown cache backend is rejected" "'cache' must be one of" INPUT_CACHE=redis
assert_fail "non-boolean push is rejected" "must be 'true' or 'false'" INPUT_PUSH=yes
assert_fail "non-boolean login is rejected" "must be 'true' or 'false'" INPUT_LOGIN=1

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all validate.sh tests passed"
```

Create `docker-build-push/test/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every bash unit test in this directory.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

status=0
for test_file in "$TEST_DIR"/*_test.sh; do
  echo "== $(basename "$test_file")"
  bash "$test_file" || status=1
done
exit "$status"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash docker-build-push/test/run.sh
```

Expected: FAIL — every assertion errors because `scripts/validate.sh` does not
exist yet (`bash: .../scripts/validate.sh: No such file or directory`).

- [ ] **Step 3: Write the implementation**

Create `docker-build-push/scripts/validate.sh`:

```bash
#!/usr/bin/env bash
# Validates action inputs before any expensive setup runs.
# Reads INPUT_* environment variables; exits 1 with an actionable message.
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

require_bool() {
  local name=$1 value=$2
  case "$value" in
    true | false) ;;
    *) fail "Input '$name' must be 'true' or 'false', got '$value'." ;;
  esac
}

: "${INPUT_IMAGE:=}"
: "${INPUT_REGISTRY:=}"
: "${INPUT_PUSH:=}"
: "${INPUT_LOGIN:=}"
: "${INPUT_USERNAME:=}"
: "${INPUT_PASSWORD:=}"
: "${INPUT_CACHE:=}"

[ -n "$INPUT_IMAGE" ] || fail "Input 'image' is required."

# The first path segment of a repository name cannot contain a dot or a colon;
# if it does, the caller has passed a registry host in the wrong input.
first_segment=${INPUT_IMAGE%%/*}
case "$first_segment" in
  *.* | *:*)
    fail "Input 'image' must not include the registry host (got '$INPUT_IMAGE'). Pass the host in 'registry' and the repository path in 'image'."
    ;;
esac

require_bool push "$INPUT_PUSH"
require_bool login "$INPUT_LOGIN"

case "$INPUT_CACHE" in
  gha | registry | none) ;;
  *) fail "Input 'cache' must be one of 'gha', 'registry', 'none', got '$INPUT_CACHE'." ;;
esac

if [ "$INPUT_PUSH" = "true" ] && [ "$INPUT_LOGIN" = "true" ]; then
  [ -n "$INPUT_USERNAME" ] ||
    fail "Input 'username' is required when pushing with login enabled. Pull requests from forks have no secrets - use 'push: false' there."
  [ -n "$INPUT_PASSWORD" ] ||
    fail "Input 'password' is required when pushing with login enabled. Pull requests from forks have no secrets - use 'push: false' there."
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash docker-build-push/test/run.sh
```

Expected: PASS — 15 `ok` lines, then `all validate.sh tests passed`.

- [ ] **Step 5: Shellcheck the new scripts**

```bash
shellcheck docker-build-push/scripts/*.sh docker-build-push/test/*.sh
```

Expected: PASS (no output).

- [ ] **Step 6: Commit**

```bash
git add docker-build-push/scripts/validate.sh docker-build-push/test/
git commit -m "feat(docker-build-push): validate inputs before expensive setup"
```

---

### Task 3: Build configuration resolution script

Turns raw inputs plus `metadata-action` output into the exact values
`build-push-action` needs: the tag list, the Dockerfile path, the cache flags,
and the primary image reference.

**Files:**
- Create: `docker-build-push/scripts/resolve-config.sh`
- Create: `docker-build-push/test/resolve_config_test.sh`

**Interfaces:**
- Consumes: `test/run.sh` from Task 2 (it discovers `*_test.sh` automatically, so no change is needed there).
- Produces: `scripts/resolve-config.sh`, invoked with environment variables `INPUT_TAGS`, `DERIVED_TAGS`, `INPUT_CONTEXT`, `INPUT_FILE`, `INPUT_CACHE`, `INPUT_PUSH`, `IMAGE_REF`, and `GITHUB_OUTPUT` pointing at a writable file. Writes these keys to `$GITHUB_OUTPUT`: `tags` (multiline), `file`, `cache-from`, `cache-to`, `image-ref`. Task 4 reads them as `steps.config.outputs.<key>`.

- [ ] **Step 1: Write the failing test**

Create `docker-build-push/test/resolve_config_test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for scripts/resolve-config.sh.
set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE="$TEST_DIR/../scripts/resolve-config.sh"

failures=0

# Runs resolve-config.sh against a temp GITHUB_OUTPUT and echoes the file.
resolve_with() {
  local out
  out=$(mktemp)
  env \
    INPUT_TAGS= \
    DERIVED_TAGS=$'docker.io/dbiagi/myapp:sha-abc1234\ndocker.io/dbiagi/myapp:latest' \
    INPUT_CONTEXT=. \
    INPUT_FILE= \
    INPUT_CACHE=gha \
    INPUT_PUSH=true \
    IMAGE_REF=docker.io/dbiagi/myapp \
    GITHUB_OUTPUT="$out" \
    "$@" \
    bash "$RESOLVE" >/dev/null 2>&1
  local status=$?
  cat "$out"
  rm -f "$out"
  return "$status"
}

# Reads a single-line key from GITHUB_OUTPUT-formatted text.
output_value() {
  local key=$1 text=$2
  printf '%s\n' "$text" | sed -n "s/^${key}=//p"
}

assert_output() {
  local desc=$1 key=$2 expected=$3
  shift 3
  local text actual
  text=$(resolve_with "$@")
  actual=$(output_value "$key" "$text")
  if [ "$actual" = "$expected" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    echo "       $key: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

assert_contains() {
  local desc=$1 needle=$2
  shift 2
  local text
  text=$(resolve_with "$@")
  if [[ "$text" == *"$needle"* ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (output did not contain '$needle')"
    echo "       output: $text"
    failures=$((failures + 1))
  fi
}

# Dockerfile path
assert_output "file defaults to context Dockerfile" file "./Dockerfile"
assert_output "trailing slash in context is not doubled" file "./Dockerfile" INPUT_CONTEXT=./
assert_output "subdirectory context" file "svc/api/Dockerfile" INPUT_CONTEXT=svc/api
assert_output "explicit file wins" file "build/prod.Dockerfile" INPUT_FILE=build/prod.Dockerfile

# Tag resolution
assert_output "primary ref is the first derived tag" image-ref "docker.io/dbiagi/myapp:sha-abc1234"
assert_contains "derived tags are emitted" "docker.io/dbiagi/myapp:latest"
assert_output "explicit tags override derivation" image-ref "docker.io/dbiagi/myapp:nightly" \
  INPUT_TAGS=$'docker.io/dbiagi/myapp:nightly\ndocker.io/dbiagi/myapp:edge'
assert_contains "explicit tags suppress derived tags" "docker.io/dbiagi/myapp:edge" \
  INPUT_TAGS=$'docker.io/dbiagi/myapp:nightly\ndocker.io/dbiagi/myapp:edge'

# Cache backends
assert_output "gha cache reads from gha" cache-from "type=gha"
assert_output "gha cache writes max mode" cache-to "type=gha,mode=max"
assert_output "registry cache reads from buildcache tag" cache-from \
  "type=registry,ref=docker.io/dbiagi/myapp:buildcache" INPUT_CACHE=registry
assert_output "registry cache writes buildcache tag" cache-to \
  "type=registry,ref=docker.io/dbiagi/myapp:buildcache,mode=max" INPUT_CACHE=registry
assert_output "registry cache does not write when not pushing" cache-to "" \
  INPUT_CACHE=registry INPUT_PUSH=false
assert_output "cache none reads nothing" cache-from "" INPUT_CACHE=none
assert_output "cache none writes nothing" cache-to "" INPUT_CACHE=none

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all resolve-config.sh tests passed"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash docker-build-push/test/run.sh
```

Expected: `validate_test.sh` passes; `resolve_config_test.sh` FAILS every
assertion because `scripts/resolve-config.sh` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `docker-build-push/scripts/resolve-config.sh`:

```bash
#!/usr/bin/env bash
# Resolves the final build configuration and writes it to $GITHUB_OUTPUT.
# Runs after metadata-action so DERIVED_TAGS is available.
set -euo pipefail

: "${INPUT_TAGS:=}"
: "${DERIVED_TAGS:=}"
: "${INPUT_CONTEXT:=.}"
: "${INPUT_FILE:=}"
: "${INPUT_CACHE:=gha}"
: "${INPUT_PUSH:=true}"
: "${IMAGE_REF:=}"

# Dockerfile path: explicit input wins, otherwise <context>/Dockerfile with any
# trailing slash on the context stripped so the path never doubles up.
file=$INPUT_FILE
if [ -z "$file" ]; then
  context=${INPUT_CONTEXT%/}
  [ -n "$context" ] || context=.
  file="$context/Dockerfile"
fi

# Explicit tags bypass derivation entirely.
tags=$INPUT_TAGS
if [ -z "${tags//[[:space:]]/}" ]; then
  tags=$DERIVED_TAGS
fi
# Strip leading and trailing blank lines so the first line is a real tag.
tags=$(printf '%s\n' "$tags" | sed '/^[[:space:]]*$/d')

# The primary reference is the first tag. Parameter expansion rather than a
# pipeline, because `set -o pipefail` plus `head` can surface SIGPIPE as 141.
primary=${tags%%$'\n'*}

case "$INPUT_CACHE" in
  gha)
    cache_from='type=gha'
    cache_to='type=gha,mode=max'
    ;;
  registry)
    cache_from="type=registry,ref=${IMAGE_REF}:buildcache"
    cache_to="type=registry,ref=${IMAGE_REF}:buildcache,mode=max"
    ;;
  none | *)
    cache_from=''
    cache_to=''
    ;;
esac

# Writing a registry cache requires push access to the registry. A build-only
# run has not logged in, so skip the write rather than fail late in buildx.
if [ "$INPUT_CACHE" = "registry" ] && [ "$INPUT_PUSH" != "true" ]; then
  cache_to=''
fi

{
  printf 'file=%s\n' "$file"
  printf 'image-ref=%s\n' "$primary"
  printf 'cache-from=%s\n' "$cache_from"
  printf 'cache-to=%s\n' "$cache_to"
  printf 'tags<<__TAGS_EOF__\n%s\n__TAGS_EOF__\n' "$tags"
} >>"$GITHUB_OUTPUT"
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash docker-build-push/test/run.sh
```

Expected: PASS — both test files report all tests passed.

- [ ] **Step 5: Shellcheck**

```bash
shellcheck docker-build-push/scripts/*.sh docker-build-push/test/*.sh
```

Expected: PASS (no output).

- [ ] **Step 6: Commit**

```bash
git add docker-build-push/scripts/resolve-config.sh docker-build-push/test/resolve_config_test.sh
git commit -m "feat(docker-build-push): resolve tags, dockerfile path and cache flags"
```

---

### Task 4: The composite action

Pure wiring: inputs, outputs, and the seven-step flow from the spec.

**Files:**
- Create: `docker-build-push/action.yml`

**Interfaces:**
- Consumes: `scripts/validate.sh` (Task 2) and `scripts/resolve-config.sh` (Task 3), with the exact environment variable names those tasks' Interfaces blocks list.
- Produces: the action's public interface — inputs `image`, `registry`, `tags`, `login`, `username`, `password`, `push`, `context`, `file`, `platforms`, `build-args`, `build-secrets`, `cache`; outputs `image-ref`, `digest`, `tags`, `metadata`. Task 5 documents exactly these names.

- [ ] **Step 1: Note the pinned versions**

Resolved against the GitHub API on 2026-09-20 and already filled in below:
`setup-qemu-action` v4.4.0, `setup-buildx-action` v4.4.1, `login-action` v4.6.0,
`metadata-action` v6.2.0, `build-push-action` v7.4.0. If executing this plan
much later, Dependabot will already have proposed newer SHAs; keep these unless
one is broken.

- [ ] **Step 2: Write the action**

Create `docker-build-push/action.yml`:

```yaml
---
name: Docker Build and Push
description: Build a Dockerfile and publish the image to any container registry.

inputs:
  image:
    description: Repository path without the registry host, e.g. dbiagi/myapp.
    required: true
  registry:
    description: Registry host, e.g. docker.io, ghcr.io, quay.io.
    required: false
    default: docker.io
  tags:
    description: >-
      Newline-separated fully-qualified tags. When set, tag derivation is
      skipped entirely.
    required: false
    default: ""
  login:
    description: >-
      Whether to log in to the registry. Set false when the caller has already
      authenticated, for example via OIDC for ECR or Artifact Registry.
    required: false
    default: "true"
  username:
    description: Registry username. Required when login and push are both true.
    required: false
    default: ""
  password:
    description: >-
      Registry password or access token. Required when login and push are both
      true.
    required: false
    default: ""
  push:
    description: >-
      Whether to push the built image. When false the image is built and
      validated only, and no credentials are needed.
    required: false
    default: "true"
  context:
    description: Build context path.
    required: false
    default: "."
  file:
    description: Dockerfile path. Defaults to <context>/Dockerfile.
    required: false
    default: ""
  platforms:
    description: Comma-separated target platforms, e.g. linux/amd64,linux/arm64.
    required: false
    default: linux/amd64
  build-args:
    description: Newline-separated KEY=value build arguments.
    required: false
    default: ""
  build-secrets:
    description: Newline-separated build secrets forwarded to buildx.
    required: false
    default: ""
  cache:
    description: Layer cache backend - gha, registry or none.
    required: false
    default: gha

outputs:
  image-ref:
    description: Primary fully-qualified image reference (the first tag).
    value: ${{ steps.config.outputs.image-ref }}
  digest:
    description: Digest of the built image.
    value: ${{ steps.build.outputs.digest }}
  tags:
    description: Newline-separated tags applied to the image.
    value: ${{ steps.config.outputs.tags }}
  metadata:
    description: Raw buildx metadata JSON.
    value: ${{ steps.build.outputs.metadata }}

runs:
  using: composite
  steps:
    # Fails before QEMU and buildx setup, which cost 10-20 seconds.
    - name: Validate inputs
      shell: bash
      env:
        INPUT_IMAGE: ${{ inputs.image }}
        INPUT_REGISTRY: ${{ inputs.registry }}
        INPUT_PUSH: ${{ inputs.push }}
        INPUT_LOGIN: ${{ inputs.login }}
        INPUT_USERNAME: ${{ inputs.username }}
        INPUT_PASSWORD: ${{ inputs.password }}
        INPUT_CACHE: ${{ inputs.cache }}
      run: bash "$GITHUB_ACTION_PATH/scripts/validate.sh"

    # Emulation is only needed for platforms the runner cannot execute natively.
    - name: Set up QEMU
      if: inputs.platforms != 'linux/amd64'
      uses: docker/setup-qemu-action@99012661954931238ded8c8b007157a8430204e1 # v4.4.0

    - name: Set up Buildx
      uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

    # A registry cache write needs credentials even when nothing is pushed,
    # which is why this is not tied to `push` alone.
    - name: Log in to registry
      if: >-
        inputs.login == 'true' &&
        (inputs.push == 'true' || inputs.cache == 'registry')
      uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
      with:
        registry: ${{ inputs.registry }}
        username: ${{ inputs.username }}
        password: ${{ inputs.password }}

    - name: Derive tags and labels
      id: meta
      if: inputs.tags == ''
      uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302 # v6.2.0
      with:
        images: ${{ inputs.registry }}/${{ inputs.image }}
        # flavor keeps its default latest=auto, which adds `latest` for stable
        # semver tag pushes (and skips pre-releases such as v1.2.3-rc1). The raw
        # entry below adds it for default-branch pushes.
        tags: |
          type=sha,format=short,prefix=sha-
          type=ref,event=branch
          type=ref,event=pr
          type=semver,pattern={{version}}
          type=semver,pattern={{major}}.{{minor}}
          type=semver,pattern={{major}}
          type=raw,value=latest,enable={{is_default_branch}}

    - name: Resolve build configuration
      id: config
      shell: bash
      env:
        INPUT_TAGS: ${{ inputs.tags }}
        DERIVED_TAGS: ${{ steps.meta.outputs.tags }}
        INPUT_CONTEXT: ${{ inputs.context }}
        INPUT_FILE: ${{ inputs.file }}
        INPUT_CACHE: ${{ inputs.cache }}
        INPUT_PUSH: ${{ inputs.push }}
        IMAGE_REF: ${{ inputs.registry }}/${{ inputs.image }}
      run: bash "$GITHUB_ACTION_PATH/scripts/resolve-config.sh"

    - name: Build and push
      id: build
      uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
      with:
        context: ${{ inputs.context }}
        file: ${{ steps.config.outputs.file }}
        platforms: ${{ inputs.platforms }}
        push: ${{ inputs.push }}
        tags: ${{ steps.config.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
        build-args: ${{ inputs.build-args }}
        secrets: ${{ inputs.build-secrets }}
        cache-from: ${{ steps.config.outputs.cache-from }}
        cache-to: ${{ steps.config.outputs.cache-to }}
        # buildx attaches provenance by default; Docker Hub renders it as
        # phantom unknown/unknown architecture rows next to the real platforms.
        provenance: false
```

- [ ] **Step 3: Verify the action file lints**

```bash
yamllint -c .yamllint.yml docker-build-push/action.yml
```

Expected: PASS (no output).

- [ ] **Step 4: Verify every third-party action is SHA-pinned**

```bash
grep -n 'uses:' docker-build-push/action.yml | grep -vE '@[0-9a-f]{40} # v[0-9]' && echo 'UNPINNED' || echo 'all pinned'
```

Expected: `all pinned`.

- [ ] **Step 5: Verify the scripts resolve at the path the action uses**

```bash
test -f docker-build-push/scripts/validate.sh &&
  test -f docker-build-push/scripts/resolve-config.sh &&
  echo "both scripts present at the action-relative path"
```

Expected: the confirmation line. `$GITHUB_ACTION_PATH` resolves to
`docker-build-push/` at runtime, so these relative paths must match.

- [ ] **Step 6: Run the full local check**

```bash
yamllint -c .yamllint.yml . &&
  shellcheck docker-build-push/scripts/*.sh docker-build-push/test/*.sh &&
  bash docker-build-push/test/run.sh
```

Expected: all three PASS.

- [ ] **Step 7: Commit**

```bash
git add docker-build-push/action.yml
git commit -m "feat(docker-build-push): add the composite action"
```

---

### Task 5: Action documentation

**Files:**
- Create: `docker-build-push/README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the input and output names from Task 4's Produces block. Every name in the tables below must match `action.yml` exactly.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the action README**

Follow `docs/knowledge/rules.md`: an inputs table, an outputs table, usage
examples, nothing else. No rationale, no design history.

Create `docker-build-push/README.md`:

````markdown
# docker-build-push

Build a Dockerfile and publish the image to any container registry.

## Inputs

| Input | Default | Description |
|---|---|---|
| `image` | *required* | Repository path without the registry host, e.g. `dbiagi/myapp`. |
| `registry` | `docker.io` | Registry host, e.g. `ghcr.io`, `quay.io`. |
| `tags` | — | Newline-separated fully-qualified tags. When set, tag derivation is skipped. |
| `login` | `true` | Set `false` when the caller has already authenticated. |
| `username` | — | Registry username. Required when `login` and `push` are both true. |
| `password` | — | Registry password or token. Required when `login` and `push` are both true. |
| `push` | `true` | `false` builds and validates without pushing, and needs no credentials. |
| `context` | `.` | Build context path. |
| `file` | `<context>/Dockerfile` | Dockerfile path. |
| `platforms` | `linux/amd64` | Comma-separated target platforms. |
| `build-args` | — | Newline-separated `KEY=value` build arguments. |
| `build-secrets` | — | Newline-separated build secrets forwarded to buildx. |
| `cache` | `gha` | Layer cache backend: `gha`, `registry` or `none`. |

## Outputs

| Output | Description |
|---|---|
| `image-ref` | Primary fully-qualified image reference (the first tag). |
| `digest` | Digest of the built image. |
| `tags` | Newline-separated tags applied to the image. |
| `metadata` | Raw buildx metadata JSON. |

## Tags

When `tags` is not set, tags are derived from the git context:

| Trigger | Tags |
|---|---|
| any build | `sha-<short>` |
| branch push | `<branch>` |
| default-branch push | `<branch>`, `latest` |
| tag push `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest` |
| pull request | `pr-<number>` |

## Usage

### Docker Hub, multi-architecture

```yaml
- uses: dbiagi/actions/docker-build-push@v1
  with:
    image: dbiagi/myapp
    platforms: linux/amd64,linux/arm64
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}
```

### GitHub Container Registry

```yaml
- uses: dbiagi/actions/docker-build-push@v1
  with:
    registry: ghcr.io
    image: ${{ github.repository }}
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

### Pull request guard — builds, never pushes, uses no secrets

```yaml
- uses: dbiagi/actions/docker-build-push@v1
  with:
    image: dbiagi/myapp
    push: false
```

### A registry the caller authenticates itself

```yaml
- uses: aws-actions/amazon-ecr-login@v2
- uses: dbiagi/actions/docker-build-push@v1
  with:
    login: false
    registry: 1234.dkr.ecr.us-east-1.amazonaws.com
    image: myapp
```

### Explicit tags

```yaml
- uses: dbiagi/actions/docker-build-push@v1
  with:
    image: dbiagi/myapp
    tags: |
      docker.io/dbiagi/myapp:nightly
      docker.io/dbiagi/myapp:${{ github.sha }}
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}
```
````

Note: every fence marked with a zero-width-prefixed backtick above is a literal
nested code block — write plain triple backticks in the file.

- [ ] **Step 2: Cross-check the README against the action**

Every input in the table must exist in `action.yml` with the same default, and
every input in `action.yml` must appear in the table.

```bash
diff <(grep -oP '^\| `\K[a-z-]+' docker-build-push/README.md | head -13 | sort) \
     <(sed -n '/^inputs:/,/^outputs:/p' docker-build-push/action.yml |
       grep -oP '^  \K[a-z-]+(?=:)' | sort) &&
  echo "inputs match"
```

Expected: `inputs match`. If not, fix the README to match `action.yml`.

- [ ] **Step 3: Verify the README lints and renders**

```bash
yamllint -c .yamllint.yml .
```

Expected: PASS. Open `docker-build-push/README.md` and confirm the five usage
blocks are separate fenced blocks, not one nested block.

- [ ] **Step 4: Update the changelog**

Edit `CHANGELOG.md`, leaving the entry under `## [Unreleased]` — Task 6 turns it
into a release.

- [ ] **Step 5: Commit**

```bash
git add docker-build-push/README.md CHANGELOG.md
git commit -m "docs(docker-build-push): document inputs, outputs and usage"
```

---

### Task 6: Release workflow, smoke test, and v1.0.0

The smoke test is the gate the lint-only CI decision requires: nothing before
this point has actually run the action.

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the whole action from Tasks 2-5.
- Produces: the published `v1` floating tag that consumers pin.

- [ ] **Step 1: Write the release workflow**

Create `.github/workflows/release.yml`, reusing the `actions/checkout` pin from
Task 1:

```yaml
---
name: Release

on:
  push:
    tags: ["v[0-9]+.[0-9]+.[0-9]+"]

permissions:
  contents: write

jobs:
  move-major-tag:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0

      - name: Move the floating major tag
        env:
          RELEASE_TAG: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          major=${RELEASE_TAG%%.*}
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -f "$major" "$RELEASE_TAG"
          git push -f origin "refs/tags/$major"
          echo "moved $major to $RELEASE_TAG"
```

- [ ] **Step 2: Lint everything one more time**

```bash
yamllint -c .yamllint.yml . &&
  shellcheck docker-build-push/scripts/*.sh docker-build-push/test/*.sh &&
  bash docker-build-push/test/run.sh
```

Expected: all three PASS.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: move the floating major tag on release"
```

- [ ] **Step 4: Create the GitHub repository and push**

**This is the first outward-facing step in the plan — it publishes the repo.
Confirm with the user before running it.**

```bash
gh repo create dbiagi/actions --public --source=. --remote=origin --push
```

Then confirm the Lint workflow ran and passed:

```bash
gh run list --limit 3
gh run watch
```

Expected: the Lint workflow succeeds. If actionlint flags anything, fix it and
push before continuing.

- [ ] **Step 5: Smoke test — build only, no credentials**

In a homelab repo that has a Dockerfile, create
`.github/workflows/smoke-docker-build-push.yml` on a scratch branch:

```yaml
---
name: Smoke test docker-build-push

on: workflow_dispatch

jobs:
  build-only:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - id: build
        uses: dbiagi/actions/docker-build-push@main
        with:
          image: dbiagi/smoke-test
          push: false
          platforms: linux/amd64,linux/arm64
      - run: |
          echo "image-ref: ${{ steps.build.outputs.image-ref }}"
          echo "tags: ${{ steps.build.outputs.tags }}"
```

Run it: `gh workflow run smoke-docker-build-push.yml && gh run watch`

Expected: the run succeeds. Confirm in the log that the QEMU step ran (it must,
since `platforms` is not the default), that both architectures were built, and
that `image-ref` printed the `sha-<short>` tag (`docker.io/dbiagi/smoke-test:sha-<short>`)
rather than an empty string or the branch tag, and that the `tags` output lists the
branch tag as well.

- [ ] **Step 6: Smoke test — a real push to Docker Hub**

Set the credentials on the homelab repo, using a Docker Hub access token rather
than your account password:

```bash
gh secret set DOCKERHUB_USERNAME
gh secret set DOCKERHUB_TOKEN
```

Change the smoke workflow's step to push:

```yaml
      - id: build
        uses: dbiagi/actions/docker-build-push@main
        with:
          image: dbiagi/smoke-test
          platforms: linux/amd64,linux/arm64
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
```

Run it again. Expected: the push succeeds, and on Docker Hub the tag lists
exactly `linux/amd64` and `linux/arm64` — **no `unknown/unknown` row**. That row
appearing means `provenance: false` did not take effect.

- [ ] **Step 7: Smoke test — the validation path**

Confirm the fail-fast behavior by running the workflow once with
`image: ghcr.io/dbiagi/smoke-test` (a host in the wrong input).

Expected: the run fails at the first step, in a few seconds, with the
`must not include the registry host` annotation — not a Docker error minutes in.

Then delete the scratch branch and the smoke workflow from the homelab repo.

- [ ] **Step 8: Release v1.0.0**

Move the `## [Unreleased]` heading in `CHANGELOG.md` to `## [1.0.0] - <today>`.

```bash
git add CHANGELOG.md
git commit -m "chore: release v1.0.0"
git push
git tag v1.0.0
git push origin v1.0.0
gh run watch
```

Expected: the Release workflow succeeds and `v1` now points at the same commit.

- [ ] **Step 9: Verify the published interface**

```bash
git ls-remote --tags origin | grep -E 'refs/tags/v1(\^\{\})?$'
```

Expected: `v1` and `v1.0.0` resolve to the same commit. From this point
`dbiagi/actions/docker-build-push@v1` is the reference consumers pin.
