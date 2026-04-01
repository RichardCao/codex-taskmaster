#!/usr/bin/env python3

import os
import struct
import sys


ICON_TYPE_BY_FILENAME = [
    ("icon_16x16.png", "icp4"),
    ("icon_32x32.png", "icp5"),
    ("icon_32x32@2x.png", "icp6"),
    ("icon_128x128.png", "ic07"),
    ("icon_256x256.png", "ic08"),
    ("icon_512x512.png", "ic09"),
    ("icon_512x512@2x.png", "ic10"),
]


def read_png_chunks(iconset_dir: str) -> bytes:
    chunks: list[bytes] = []
    for filename, icon_type in ICON_TYPE_BY_FILENAME:
        path = os.path.join(iconset_dir, filename)
        if not os.path.isfile(path):
            raise FileNotFoundError(f"missing iconset file: {path}")
        with open(path, "rb") as handle:
            data = handle.read()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"not a PNG file: {path}")
        chunk = icon_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data
        chunks.append(chunk)
    return b"".join(chunks)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make_icns.py ICONSET_DIR OUTPUT_ICNS", file=sys.stderr)
        return 2

    iconset_dir, output_path = sys.argv[1], sys.argv[2]
    payload = read_png_chunks(iconset_dir)
    blob = b"icns" + struct.pack(">I", len(payload) + 8) + payload

    with open(output_path, "wb") as handle:
        handle.write(blob)

    print(f"Wrote icns: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
