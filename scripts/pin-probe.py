#!/usr/bin/env python3
# Probe main TLMM mi2s2 pins gpio133/135/137 (alioth speaker pins per hakios).
# Main TLMM base 0x0f100000 (WEST). Pins at 0x1000 stride.
import mmap, os, sys, struct

BASE = 0x0f100000
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x200000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

def rd(off):
    return struct.unpack("<I", m[off:off+4])[0]

mode = sys.argv[1] if len(sys.argv) > 1 else "idle"
for pin, name in [(133, "TERT_SCLK"), (135, "TERT_WS"), (137, "TERT_DATA1"),
                  (134, "TERT_DATA0")]:
    cfg_off = pin * 0x1000
    val_off = cfg_off + 0x4
    cfg = rd(cfg_off)
    ones = 0; trans = 0; prev = -1; N = 20000
    for i in range(N):
        v = rd(val_off) & 1
        ones += v
        if prev >= 0 and v != prev:
            trans += 1
        prev = v
    func = (cfg >> 2) & 0xf
    oe = (cfg >> 9) & 1
    print(f"{name} pin{pin} cfg=0x{cfg:08x} func={func} OE={oe} ones={ones}/{N} transitions={trans}")
m.close(); os.close(fd)