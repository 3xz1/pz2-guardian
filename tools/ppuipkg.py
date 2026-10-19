"""Unpack / pack cobra-tools .ppuipkg XML (UI packages) to / from plain files.

  ppuipkg.py unpack <pkg.ppuipkg> <outDir>
  ppuipkg.py pack <srcDir> <basic_path> <out.ppuipkg>

On pack, every file under srcDir is stored with its path relative to srcDir
(forward slashes), e.g. srcDir/UIGameface/foo.html -> UIGameface/foo.html.
"""
import os
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape


def unpack(pkg, out_dir):
    root = ET.parse(pkg).getroot()
    print("basic_path:", root.findtext("basic_path"))
    for f in root.find("files"):
        name = f.findtext("file_name")
        # cobra-tools writes file bytes as signed chars (-128..127)
        data = bytes(int(b) & 0xFF for b in (f.findtext("file_content") or "").split())
        path = os.path.join(out_dir, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        print(f"{len(data):8d}  {name}")


def pack(src_dir, basic_path, out):
    entries = []
    for dirpath, _, files in os.walk(src_dir):
        for fn in sorted(files):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
            with open(full, "rb") as fh:
                entries.append((rel, fh.read()))
    entries.sort()
    lines = [f'<PPUIPKGRoot file_count="{len(entries)}" icondata_count="0" game="Planet Coaster 2">',
             f"\t<basic_path>{escape(basic_path)}</basic_path>", "\t<files>"]
    for rel, data in entries:
        lines += [f'\t\t<ppuipkgfile file_size="{len(data)}">',
                  f"\t\t\t<file_name>{escape(rel)}</file_name>",
                  f"\t\t\t<file_content>{' '.join(str(b - 256 if b > 127 else b) for b in data)}</file_content>",
                  "\t\t</ppuipkgfile>"]
    lines += ["\t</files>", "\t<types />", "</PPUIPKGRoot>", ""]
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    for rel, data in entries:
        print(f"{len(data):8d}  {rel}")


if __name__ == "__main__":
    if sys.argv[1] == "unpack":
        unpack(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "pack":
        pack(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
