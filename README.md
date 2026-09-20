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
