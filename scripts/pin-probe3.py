#!/usr/bin/env python3
# LPI pin0 SCLK probe v3: KEEP func2 mux, read pad input bit0 in tight loop.
# A running 12.288MHz clock aliases to a mix of 0/1; a dead clock reads all 0 (or all 1).
import mmap, os, sys, time, struct

BASE = 0x033c0000
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x4000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

def rd(off):
    return struct.unpack("<I", m[off:off+4])[0]

mode = sys.argv[1] if len(sys.argv) > 1 else "idle"
for pin, name, cfgoff, valoff in [(0,"SCLK",0x0000,0x0004),(1,"WS",0x1000,0x1004),(2,"DATA",0x2000,0x2004)]:
    cfg = rd(cfgoff)
    # tight-loop sample pad input bit0, keep mux untouched
    ones = 0; trans = 0; prev = -1; N = 20000
    for i in range(N):
        v = rd(valoff) & 1
        ones += v
        if prev >= 0 and v != prev:
            trans += 1
        prev = v
    print(f"{name} pin{pin} cfg=0x{cfg:08x} func={(cfg>>2)&0xf} OE={(cfg>>9)&1} ones={ones}/{N} transitions={trans}")
m.close(); os.close(fd)