#!/usr/bin/env bash
set -euo pipefail

if [ -n "${NIX_BUILD_TOP:-}" ]; then
  # Running inside a sandboxed Nix build (e.g. `nix flake check`'s
  # pre-commit derivation), which has no network access and thus cannot
  # fetch the Git dependency needed to verify the lock file.
  echo 'No network access in sandboxed Nix build - skipping zon2lock check.'
  exit 0
fi

before="$(mktemp)"
trap 'rm -f "$before"' EXIT

if [ -f build.zig.zon2json-lock ]; then
  cp build.zig.zon2json-lock "$before"
else
  : > "$before"
fi

# Writes directly to build.zig.zon2json-lock (its default destination),
# updating it in place.
zig2nix zon2lock build.zig.zon

# zig2nix does not terminate the file with a newline; add one if missing.
if [ -n "$(tail -c1 build.zig.zon2json-lock)" ]; then
  printf '\n' >> build.zig.zon2json-lock
fi

if ! diff -u "$before" build.zig.zon2json-lock; then
  echo >&2
  echo "build.zig.zon2json-lock was out of date with build.zig.zon and has been updated." >&2
  echo "Review the changes and commit build.zig.zon2json-lock." >&2
  exit 1
fi
