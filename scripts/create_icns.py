from __future__ import annotations

import struct
import sys
from pathlib import Path


source_dir = Path(sys.argv[1])
output_path = Path(sys.argv[2])
icon_files = [
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
]

elements = []
for icon_type, filename in icon_files:
    image_data = (source_dir / filename).read_bytes()
    elements.append(icon_type + struct.pack(">I", len(image_data) + 8) + image_data)

payload = b"".join(elements)
output_path.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
