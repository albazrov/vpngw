#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/vpn-functions.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PRIVATE_DIR="$TEST_DIR/private"
mkdir "$PRIVATE_DIR"
chmod 0700 "$PRIVATE_DIR"
ensure_private_directory "$PRIVATE_DIR" "$(id -u)" "$(id -g)" 700

chmod 0777 "$PRIVATE_DIR"
if ensure_private_directory "$PRIVATE_DIR" "$(id -u)" "$(id -g)" 700; then
    printf 'Expected world-writable directory to be rejected\n' >&2
    exit 1
fi

chmod 0700 "$PRIVATE_DIR"
ln -s "$PRIVATE_DIR" "$TEST_DIR/runtime-link"
if ensure_private_directory "$TEST_DIR/runtime-link" "$(id -u)" "$(id -g)" 700; then
    printf 'Expected symlinked runtime directory to be rejected\n' >&2
    exit 1
fi

STATS_DIR="$PRIVATE_DIR"
if ensure_stats_dir; then
    printf 'Expected non-production stats path to be rejected\n' >&2
    exit 1
else
    result=$?
    [[ "$result" -eq 2 ]]
fi

printf 'Runtime directory permission tests passed\n'
