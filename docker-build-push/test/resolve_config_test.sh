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
