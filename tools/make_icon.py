import struct, zlib, sys

# Simple hand-drawn app icon, pure stdlib (no PIL available): a dark
# rounded-square-ish background with a centered red filled circle (a
# "record" symbol), thin white ring around it. 512x512 RGBA.

SIZE = 512
CX, CY = SIZE / 2, SIZE / 2
R_OUTER = 200
R_RING_INNER = 188
R_DOT = 150

BG = (40, 42, 48, 255)
RING = (235, 235, 235, 255)
RED = (214, 48, 49, 255)
TRANSPARENT = (0, 0, 0, 0)

CORNER_RADIUS = 90

def in_rounded_square(x, y):
    # distance from nearest edge accounting for rounded corners
    nx = min(x, SIZE - 1 - x)
    ny = min(y, SIZE - 1 - y)
    if nx >= CORNER_RADIUS or ny >= CORNER_RADIUS:
        return True
    dx = CORNER_RADIUS - nx
    dy = CORNER_RADIUS - ny
    return (dx * dx + dy * dy) <= CORNER_RADIUS * CORNER_RADIUS

pixels = bytearray(SIZE * SIZE * 4)
for y in range(SIZE):
    for x in range(SIZE):
        idx = (y * SIZE + x) * 4
        if not in_rounded_square(x, y):
            r, g, b, a = TRANSPARENT
        else:
            dx = x - CX
            dy = y - CY
            dist2 = dx * dx + dy * dy
            if dist2 <= R_DOT * R_DOT:
                r, g, b, a = RED
            elif dist2 <= R_OUTER * R_OUTER and dist2 >= R_RING_INNER * R_RING_INNER:
                r, g, b, a = RING
            else:
                r, g, b, a = BG
        pixels[idx] = r
        pixels[idx + 1] = g
        pixels[idx + 2] = b
        pixels[idx + 3] = a

def write_png(path, width, height, rgba):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0
        raw.extend(rgba[y * stride:(y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))

write_png(sys.argv[1] if len(sys.argv) > 1 else "icon_512.png", SIZE, SIZE, pixels)
print("wrote icon")
