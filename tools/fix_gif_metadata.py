"""Set preview timing and looping; WPF's encoder drops these metadata fields."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
assert data[:6] in (b"GIF87a", b"GIF89a")
start = 13 + (3 * (2 ** ((data[10] & 7) + 1)) if data[10] & 128 else 0)
position = start
frames = 0
controls = 0

def skip_blocks(position):
    while data[position]:
        position += 1 + data[position]
    return position + 1

while data[position] != 0x3B:
    if data[position] == 0x21:
        if data[position + 1] == 0xF9:
            assert data[position + 2] == 4
            data[position + 4:position + 6] = (5).to_bytes(2, "little")
            controls += 1
        position = skip_blocks(position + 2)
    elif data[position] == 0x2C:
        packed = data[position + 9]
        position += 10
        if packed & 128:
            position += 3 * (2 ** ((packed & 7) + 1))
        position = skip_blocks(position + 1)
        frames += 1
    else:
        raise ValueError(f"Unexpected GIF block at {position}")
assert frames == controls and frames > 0
loop = b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00"
data[start:start] = loop
path.write_bytes(data)
print(f"Verified {frames} GIF frames at 50 ms, looping")
