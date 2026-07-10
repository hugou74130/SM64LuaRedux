#!/usr/bin/env bash
#
# Copyright (c) 2025, Mupen64 maintainers.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Offline check for the parts of SM64 Lua Redux that do not need the emulator:
#   1. Byte-compile every Lua file under src/ (and test/) to catch syntax errors.
#   2. Run the Auto-Route geometry unit test.
#
# Usage: test/run.sh   (from the repository root or anywhere; paths are resolved)

set -euo pipefail

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# Pick a Lua 5.4 interpreter and compiler.
LUA="$(command -v lua5.4 || command -v lua || true)"
LUAC="$(command -v luac5.4 || command -v luac || true)"

if [[ -z "${LUA}" || -z "${LUAC}" ]]; then
    echo "error: lua5.4 / luac5.4 not found. Install with: sudo apt-get install -y lua5.4" >&2
    exit 127
fi

echo "== Syntax check (${LUAC}) =="
fail=0
while IFS= read -r f; do
    if ! "${LUAC}" -p "$f" 2>/tmp/luac_err; then
        echo "SYNTAX FAIL: $f"
        cat /tmp/luac_err
        fail=1
    fi
done < <(find src test -name '*.lua' | sort)
rm -f /tmp/luac_err
if [[ "${fail}" -ne 0 ]]; then
    echo "Syntax check failed." >&2
    exit 1
fi
echo "All Lua files parse."

echo
echo "== Auto-Route geometry test (${LUA}) =="
"${LUA}" test/autoroute_geometry_test.lua
