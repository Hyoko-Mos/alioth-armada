#!/usr/bin/env python3
# Scan ALL 14 LPI pins for activity during playback (find where BCLK actually is).
import mmap, os, sys, time, struct

BASE = 0x033c0000
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x4000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

def rd(off):
    return struct.unpack("<I", m[off:off+4])[0]

mode = sys.argv[1] if len(sys.argv) > 1 else "idle"
print(f"MODE={mode}")
for pin in range(14):
    cfg_off = pin * 0x1000
    val_off = cfg_off + 0x4
    cfg = rd(cfg_off)
    if cfg == 0:
        print(f"pin{pin}: cfg=0 (unused)")
        continue
    ones = 0; trans = 0; prev = -1; N = 5000
    for i in range(N):
        v = rd(val_off) & 1
        ones += v
        if prev >= 0 and v != prev:
            trans += 1
        prev = v
    func = (cfg >> 2) & 0xf
    oe = (cfg >> 9) & 1
    print(f"pin{pin}: cfg=0x{cfg:08x} func={func} OE={oe} ones={ones}/{N} trans={trans}")
m.close(); os.close(fd)