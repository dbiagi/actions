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
