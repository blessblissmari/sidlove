#!/usr/bin/env bash
# run_tests.sh - run the sidlove test suite with the first Lua available.
# LuaJIT exercises the native engines (bundled .so files); plain Lua 5.1
# exercises the pure-Lua path that love.js uses. Both must pass.
set -u
cd "$(dirname "$0")"

RUNNER=""
for c in luajit lua lua5.1 lua51; do
  if command -v "$c" >/dev/null 2>&1; then RUNNER="$c"; break; fi
done

if [ -z "$RUNNER" ]; then
  echo "No Lua interpreter found. Install luajit or lua5.1:"
  echo "  apt install luajit    # native engines"
  echo "  apt install lua5.1    # pure-Lua (web) path"
  exit 2
fi

echo "runner: $RUNNER"
exec "$RUNNER" tests/run.lua
