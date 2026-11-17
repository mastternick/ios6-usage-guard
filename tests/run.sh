#!/bin/sh
# Host test runner for the pure C cycle engine. Requires a C99 compiler only.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CC=${CC:-gcc}
BIN=${TMPDIR:-/tmp}/usageguard_core_tests

"$CC" -std=c99 -Wall -Wextra -Werror -O2 \
    -I"$ROOT/src" \
    "$ROOT/src/UGGuardCore.c" \
    "$ROOT/tests/test_guard_core.c" \
    -o "$BIN"

"$BIN"
