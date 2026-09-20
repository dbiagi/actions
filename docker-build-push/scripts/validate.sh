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
[ -n "$INPUT_REGISTRY" ] || fail "Input 'registry' must not be empty."

# The first path segment of a repository name cannot contain a dot or a colon;
# if it does, the caller has passed a registry host in the wrong input. Only a
# path with a '/' has a host segment; a slash-less name with a ':' carries a tag.
case "$INPUT_IMAGE" in
  */*)
    first_segment=${INPUT_IMAGE%%/*}
    case "$first_segment" in
      *.* | *:*)
        fail "Input 'image' must not include the registry host (got '$INPUT_IMAGE'). Pass the host in 'registry' and the repository path in 'image'."
        ;;
    esac
    ;;
  *:*)
    fail "Input 'image' must not include a tag or digest (got '$INPUT_IMAGE'). Tags are derived, or pass them via 'tags'."
    ;;
esac

require_bool push "$INPUT_PUSH"
require_bool login "$INPUT_LOGIN"

case "$INPUT_CACHE" in
  gha | registry | none) ;;
  *) fail "Input 'cache' must be one of 'gha', 'registry', 'none', got '$INPUT_CACHE'." ;;
esac

# Mirrors the login condition in action.yml: the action logs in when pushing, or
# when a registry cache is used with a username supplied.
if [ "$INPUT_LOGIN" = "true" ] && { [ "$INPUT_PUSH" = "true" ] || { [ "$INPUT_CACHE" = "registry" ] && [ -n "$INPUT_USERNAME" ]; }; }; then
  [ -n "$INPUT_USERNAME" ] ||
    fail "Input 'username' is required when the action will log in (pushing, or using a registry cache with a username). Pull requests from forks have no secrets - use 'push: false' and leave 'username' empty."
  [ -n "$INPUT_PASSWORD" ] ||
    fail "Input 'password' is required when the action will log in (pushing, or using a registry cache with a username). Pull requests from forks have no secrets - use 'push: false' and leave 'username' empty."
fi
