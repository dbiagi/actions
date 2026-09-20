# Design: `docker-build-push` composite action

Date: 2026-09-20
Status: Approved, ready for implementation planning

## Context

The homelab needs CI that builds a Dockerfile and publishes the image. Docker
Hub is the first target; other registries follow. Rather than one action per
registry, a single registry-agnostic action covers all of them, because
`docker/login-action` and `docker/build-push-action` already treat the registry
host as a parameter.

The action lives in a monorepo of custom actions (`dbiagi/actions`), one folder
per action. That choice was made deliberately: a solo homelab pays more for
repo sprawl than it gains from independent per-action versioning, and reusable
workflows — likely to appear later — must live at `.github/workflows/` in a
single repo anyway. The cost accepted is repo-wide versioning: a release driven
by one action bumps the version every other action's consumers see.

## Goals

- One action that builds and publishes to any registry taking username/password.
- Sensible tags derived from git context, with a full override escape hatch.
- Multi-architecture builds, layer caching, build args and build secrets.
- A build-only mode that needs no credentials, so the same action guards PRs.
- A layout future actions drop into without restructuring anything.

## Non-goals (v1)

Cosign signing, SBOM and provenance attestations, a `target` build-stage input,
and multi-image matrix builds. Each is a plausible future input; none has a use
case today. Cloud OIDC (ECR, Artifact Registry) is handled by the `login: false`
escape hatch rather than built in.

## Repository layout

```
actions/
├── .github/
│   ├── dependabot.yml          # github-actions ecosystem, one entry per directory
│   └── workflows/
│       ├── lint.yml            # actionlint + yamllint on PR and main
│       └── release.yml         # on v*.*.* tag push, move the floating major tag
├── docker-build-push/
│   ├── action.yml
│   └── README.md               # inputs, outputs, examples per registry
├── docs/
│   ├── knowledge/rules.md      # repo-wide conventions
│   └── superpowers/specs/      # design docs
├── .yamllint.yml
├── README.md                   # index: one line per action
├── CHANGELOG.md
└── LICENSE
```

Each action is a self-contained folder with its own README. The root README is
an index. Future actions (`helm-release/`, `buildpack-publish/`) are added
beside `docker-build-push/` with no change to existing files.

### Action README

Every action folder contains a `README.md`, kept as simple as possible. It has
exactly two required parts:

1. **Inputs** — a table of every input the action accepts, with its default and
   a one-line description. Outputs get the same treatment when the action has
   any.
2. **Usage examples** — copy-pasteable `uses:` snippets covering the common
   cases. For `docker-build-push` that means one per registry (Docker Hub,
   GHCR, caller-authenticated) plus the `push: false` PR guard.

Nothing else is required. No rationale, no design history, no exhaustive prose —
that belongs in this spec. The README answers "what can I pass, and what does a
working call look like", and stops there.

This is a repo-wide rule, recorded in `docs/knowledge/rules.md`.

### Naming

`docker-build-push`, not `docker-publish`: with `push: false` the action does
build-only work, so "publish" would be inaccurate in that mode. The name also
mirrors the upstream `docker/build-push-action` it wraps.

### Versioning

Repo-wide semver. Tagging `v1.0.0` triggers `release.yml`, which force-moves the
`v1` tag to the same commit. Consumers pin `dbiagi/actions/docker-build-push@v1`
and receive fixes automatically.

## Implementation approach

A **composite action wrapping the official `docker/*` actions**:
`setup-qemu-action`, `setup-buildx-action`, `login-action`, `metadata-action`,
`build-push-action`.

Two alternatives were considered and rejected. A **TypeScript action** would
mean reimplementing `docker/metadata-action`'s tag semantics (semver parsing, PR
refs, `latest` rules) and maintaining a Node build toolchain, for an action
whose job is assembling a `docker buildx` command line. A **bash composite
shelling out to `docker buildx`** avoids third-party dependencies but rewrites
login, QEMU registration, cache flags and tag derivation by hand — trading
dependency-pinning work for bug-hunting work.

The value of this action is its interface, not a reimplementation of Docker's
build plumbing. The composite approach also sets the pattern future actions in
this repo follow.

## Interface

### Inputs

| Input | Default | Notes |
|---|---|---|
| `image` | *required* | Repository path **without** the registry host: `dbiagi/myapp`. Full ref is `<registry>/<image>`. |
| `registry` | `docker.io` | Host only. `ghcr.io`, `quay.io`, `1234.dkr.ecr.us-east-1.amazonaws.com`. |
| `tags` | — | Newline-separated **fully-qualified** tags. When set, derivation is skipped entirely. |
| `login` | `true` | `false` when the caller already authenticated (ECR/GAR via OIDC). |
| `username` | — | Required when `login` is true and a push will happen. |
| `password` | — | Required when `login` is true and a push will happen. |
| `push` | `true` | `false` builds and validates without pushing, and without needing credentials. |
| `context` | `.` | Build context path. |
| `file` | `<context>/Dockerfile` | Dockerfile path. |
| `platforms` | `linux/amd64` | Comma-separated. QEMU is set up only for non-native platforms. |
| `build-args` | — | Newline-separated `KEY=value`. |
| `build-secrets` | — | Newline-separated, forwarded to buildx `secrets`. |
| `cache` | `gha` | One of `gha`, `registry`, `none`. |

### Derived tags

When `tags` is empty, `docker/metadata-action` produces:

| Trigger | Tags |
|---|---|
| any build | `sha-<short>` |
| branch push | `<branch>` (slugified) |
| default-branch push | `<branch>`, `latest` |
| tag push `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest` |
| pull request | `pr-<number>` |

`latest` is configured explicitly (`flavor: latest=false` plus a `type=raw`
entry) rather than left to `latest=auto`, so it applies to both default-branch
pushes and semver tags.

OCI labels (`org.opencontainers.image.source`, `.revision`, `.created`) come
from the same step at no extra cost.

### Outputs

| Output | Notes |
|---|---|
| `image-ref` | Primary fully-qualified ref (first resolved tag) |
| `digest` | Image digest from `build-push-action` |
| `tags` | Newline-separated, as applied |
| `metadata` | Raw buildx metadata JSON |

### Usage

```yaml
# Docker Hub, multi-arch, publish on main
- uses: dbiagi/actions/docker-build-push@v1
  with:
    image: dbiagi/myapp
    platforms: linux/amd64,linux/arm64
    username: ${{ secrets.DOCKERHUB_USERNAME }}
    password: ${{ secrets.DOCKERHUB_TOKEN }}

# GHCR
- uses: dbiagi/actions/docker-build-push@v1
  with:
    registry: ghcr.io
    image: ${{ github.repository }}
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

# PR guard — builds, never pushes, touches no secrets
- uses: dbiagi/actions/docker-build-push@v1
  with:
    image: dbiagi/myapp
    push: false

# ECR — caller authenticates via OIDC first
- uses: aws-actions/amazon-ecr-login@v2
- uses: dbiagi/actions/docker-build-push@v1
  with:
    login: false
    registry: 1234.dkr.ecr.us-east-1.amazonaws.com
    image: myapp
```

## Internals

### Step flow

1. **Validate** — bash, runs first, before anything expensive. See below.
2. **QEMU** — `docker/setup-qemu-action`, only when `platforms` asks for
   anything beyond `linux/amd64`.
3. **Buildx** — `docker/setup-buildx-action`, always; needed for cache and
   manifest lists.
4. **Login** — `docker/login-action`, when
   `login == 'true' && (push == 'true' || cache == 'registry')`. The registry-cache
   case is why this is not tied to `push` alone.
5. **Metadata** — `docker/metadata-action`, skipped when `tags` was supplied.
6. **Build and push** — `docker/build-push-action`, with `provenance: false`
   and `cache-from`/`cache-to` derived from `cache`.
7. **Outputs** — bash step resolving `image-ref` from the first tag.

### Validation rules (step 1)

Each failure exits non-zero with a message naming the offending input:

- `image` whose first path segment looks like a host (contains `.` or `:`) —
  tell the caller to pass it via `registry`.
- `push == 'true'` and `login == 'true'` with an empty `username` or `password` —
  name which one is missing, and mention `push: false` for fork PRs.
- `cache` outside `gha`, `registry`, `none`.

QEMU and buildx setup cost 10–20 seconds. Failing before them turns a confusing
deep Docker error into a one-line message.

### Known failure modes, handled

**Composite inputs are always strings.** `if: inputs.push` is truthy for the
literal string `"false"`. Every boolean comparison is written
`inputs.push == 'true'`. This is the most common way composite actions break,
and it fails silently rather than loudly.

**Fork PRs have no secrets.** A fork PR with `push: true` gets an empty
password. Validation fails it immediately, pointing at `push: false`, instead of
a `docker login` auth error 40 seconds in.

**Docker Hub shows phantom architectures.** buildx attaches provenance
attestations by default when pushing, and Docker Hub renders them as
`unknown/unknown` architecture rows beside the real platforms. The action sets
`provenance: false`. Attestations become an opt-in input if ever wanted.

### Dependency pinning

Every `docker/*` step is pinned to a full commit SHA with a trailing version
comment (`# v6.9.0`). Dependabot needs two entries in `.github/dependabot.yml` —
`directory: "/"` for the workflows and `directory: "/docker-build-push"` for the
action's own `action.yml` — because the `github-actions` ecosystem only scans
directories named explicitly.

## Verification

CI is **lint-only** by decision: `actionlint` (which also shellchecks inline
bash) plus `yamllint`. This catches composite-action schema errors and shell
mistakes, but cannot catch a mis-plumbed input — a logic regression will surface
in a consuming repo rather than here.

To offset that, the plan includes **one manual smoke test before tagging
`v1.0.0`**: build and push a real homelab image with the action referenced at
`@main`, exercising multi-arch, cache and push.

### Deferred: self-test workflow

If functional CI is wanted later, the shape is a fixture Dockerfile plus a
workflow calling the action with `push: false` on PRs and pushing to
`ghcr.io` on main. Public GHCR packages have free storage and bandwidth and no
Docker Hub-style pull limits, so pushes cost nothing.

The one detail to get right is the fixture's base image. `FROM alpine` pulls
from Docker Hub on every run and counts against the unauthenticated per-IP
allowance shared across GitHub-hosted runners — the classic
`toomanyrequests` failure. Use `mirror.gcr.io/library/alpine` instead: no Docker
Hub quota, and a real `RUN` step that genuinely exercises QEMU on the arm64 leg.
(`FROM scratch` pulls nothing but has no shell, so it never exercises
emulation.)

The repo layout above accommodates this without rework.
