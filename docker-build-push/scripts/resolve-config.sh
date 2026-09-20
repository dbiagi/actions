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
# Drop blank lines so the first line is a real tag.
tags=$(printf '%s\n' "$tags" | sed '/^[[:space:]]*$/d')

[ -n "$tags" ] || {
  echo "::error::No tags resolved. Provide 'tags' or let the action derive them." >&2
  exit 1
}

# The primary reference is the sha tag (sha-<hex>), which is one per commit and
# so does not move. metadata-action lists the branch tag first, which does move.
# Fall back to the first tag when none is a sha tag (e.g. explicit `tags`).
# Parameter expansion and a here-string rather than a pipeline, because
# `set -o pipefail` plus `head` can surface SIGPIPE as 141.
primary=${tags%%$'\n'*}
while IFS= read -r tag; do
  if [[ $tag =~ :sha-[0-9a-f]+$ ]]; then
    primary=$tag
    break
  fi
done <<<"$tags"

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
