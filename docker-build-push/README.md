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
