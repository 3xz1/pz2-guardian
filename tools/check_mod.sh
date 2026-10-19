#!/usr/bin/env bash
# Offline checks for a mod source folder: Lua syntax (luaparser), JS syntax
# (node --check), the version number (Lua Core.sVersion = main.js VERSION =
# README.md / README.txt first line), and every tests/*.py (lupa harnesses, run with the
# mod's lua folder as argument).
#
#   tools/check_mod.sh <src_dir>
#
# PZ2_PYTHON overrides the Python to use (CI: a Python with lupa + luaparser).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${PZ2_PYTHON:-$(dirname "$HERE")/toolchain/venv/Scripts/python.exe}"
SRC="$(cd "$1" && pwd)"
FAIL=0

for f in "$SRC"/lua/*.lua; do
	if "$PY" -I -c "import sys; from luaparser import ast; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" 2>/dev/null; then
		echo "lua ok   $(basename "$f")"
	else
		echo "LUA FAIL $(basename "$f")"; FAIL=1
	fi
done

TMP="$(mktemp -d)"
while IFS= read -r f; do
	# node needs .mjs to parse ES module syntax outside a package
	cp "$f" "$TMP/check.mjs"
	if node --check "$TMP/check.mjs" 2>/dev/null; then
		echo "js ok    ${f#$SRC/}"
	else
		echo "JS FAIL  ${f#$SRC/}"; node --check "$TMP/check.mjs"; FAIL=1
	fi
done < <(find "$SRC/ui" -name '*.js' 2>/dev/null)
rm -rf "$TMP"

# one version everywhere, so a player's log shows which build runs
V_LUA="$(sed -n 's/^Core\.sVersion = "\([0-9.]*\)"/\1/p' "$SRC"/lua/*.core.lua | head -1)"
V_JS="$(sed -n "s/^const VERSION = '\([0-9.]*\)';/\1/p" "$SRC"/ui/UIGameface/js/mods/*/main.js | head -1)"
README="$SRC/README.md"; [ -f "$README" ] || README="$SRC/README.txt"
V_TXT="$(head -1 "$README" 2>/dev/null | sed -n 's/.*(version \([0-9.]*\)).*/\1/p')"
if [ -n "$V_LUA" ] && [ "$V_LUA" = "$V_JS" ] && [ "$V_LUA" = "$V_TXT" ]; then
	echo "version  $V_LUA (lua, js, README)"
else
	echo "VERSION MISMATCH: lua '$V_LUA', js '$V_JS', README '$V_TXT'"; FAIL=1
fi

for t in "$SRC"/tests/*.py; do
	[ -f "$t" ] || continue
	echo "--- $(basename "$t")"
	"$PY" -I "$t" "$SRC/lua" || FAIL=1
done

[ $FAIL -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "CHECKS FAILED"; exit 1; }
