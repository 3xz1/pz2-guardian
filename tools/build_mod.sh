#!/usr/bin/env bash
# Builds a content-pack mod from a source folder.
#
#   tools/build_mod.sh <src_dir> [out_dir]
#
# <src_dir> must contain:
#   Manifest.xml   <ContentPack><Name>PACK</Name>...  (PACK = folder/pack name)
#   lua/           *.lua files, named <module.name.lowercase>.lua
#                  (database.<pack>luadatabase.lua is the entry point)
#   ui/            optional; files as served, e.g. ui/UIGameface/PACKHUD.html
#   README.md      optional (or README.txt), copied next to Win64/
# Output: <out_dir>/Win64/ovldata/PACK/{Manifest.xml, Main.ovl, UI/PACKUI.ovl}
# (default out_dir: <src_dir>/dist)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TC="$(dirname "$HERE")/toolchain"
PY="$TC/venv/Scripts/python.exe"
COBRA="$TC/cobra-tools"
SRC="$(cd "$1" && pwd)"
DIST="${2:-$SRC/dist}"
PACK="$(sed -n 's:.*<Name>\(.*\)</Name>.*:\1:p' "$SRC/Manifest.xml" | head -1)"
[ -n "$PACK" ] || { echo "no <Name> in $SRC/Manifest.xml"; exit 1; }
[ -x "$PY" ] || { echo "toolchain missing: run tools/setup_toolchain.sh"; exit 1; }

WORK="$SRC/.build"
OUT="$DIST/Win64/ovldata/$PACK"
rm -rf "$WORK" "$DIST"
mkdir -p "$WORK/lua" "$OUT"

cp "$SRC"/lua/*.lua "$WORK/lua/"
(cd "$COBRA" && "$PY" ovl_tool_cmd.py new -i "$WORK/lua" -g "Planet Coaster 2" -c ZLIB -o "$OUT/Main.ovl" -f 2>&1 | grep -E "ERROR|Traceback" || true)
FILES=("$OUT/Main.ovl")

if [ -d "$SRC/ui" ]; then
	mkdir -p "$WORK/ui" "$OUT/UI"
	PKG="$(echo "$PACK" | tr '[:upper:]' '[:lower:]')ui.ppuipkg"
	"$PY" -I "$HERE/ppuipkg.py" pack "$SRC/ui" "$PACK/UI" "$WORK/ui/$PKG" > /dev/null
	(cd "$COBRA" && "$PY" ovl_tool_cmd.py new -i "$WORK/ui" -g "Planet Coaster 2" -c ZLIB -o "$OUT/UI/${PACK}UI.ovl" -f 2>&1 | grep -E "ERROR|Traceback" || true)
	FILES+=("$OUT/UI/${PACK}UI.ovl")
fi

# Header byte 4 is the platform flag: the game and working PZ2 mods use 0x01,
# cobra-tools writes 0x00.
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "build failed: $f missing"; exit 1; }
	printf '\x01' | dd of="$f" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null
done

cp "$SRC/Manifest.xml" "$OUT/"
for r in README.md README.txt; do [ -f "$SRC/$r" ] && { cp "$SRC/$r" "$DIST/"; break; }; done
rm -rf "$WORK"
echo "built $PACK:"
find "$DIST" -type f -printf '  %8s  %P\n'
