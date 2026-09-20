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
assert_pass "dotted single-segment image is allowed" INPUT_IMAGE=my.app
assert_pass "registry cache without push and without username needs no login" \
  INPUT_PUSH=false INPUT_CACHE=registry INPUT_USERNAME= INPUT_PASSWORD=
assert_pass "registry cache without push but with full credentials is allowed" \
  INPUT_PUSH=false INPUT_CACHE=registry
assert_pass "username without password is fine when no login will happen" \
  INPUT_PUSH=false INPUT_CACHE=gha INPUT_PASSWORD=

assert_fail "image carrying a registry host is rejected" "must not include the registry host" \
  INPUT_IMAGE=ghcr.io/dbiagi/myapp
assert_fail "image carrying a host with a port is rejected" "must not include the registry host" \
  INPUT_IMAGE=localhost:5000/myapp
assert_fail "image carrying a tag is rejected" "must not include a tag" INPUT_IMAGE=myapp:1.0
assert_fail "empty registry is rejected" "'registry' must not be empty" INPUT_REGISTRY=
assert_fail "registry cache with a username but no password is rejected" "'password' is required" \
  INPUT_PUSH=false INPUT_CACHE=registry INPUT_PASSWORD=
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
