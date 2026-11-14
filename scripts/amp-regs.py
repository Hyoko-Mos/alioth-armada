#!/usr/bin/env python3
# CS35L41 raw-I2C power-up sequence (bypasses the kernel driver).
# Usage: amp-regs.py on|off   (on: power up + unmute; off: mute + GLOBAL_EN=0)
import ctypes, fcntl, os, struct, sys, time

I2C_SLAVE_FORCE = 0x0706
I2C_RDWR = 0x0707
I2C_M_RD = 0x0001

class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.c_void_p)]

class i2c_rdwr_ioctl_data(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]

class Amp:
    def __init__(self, addr):
        self.fd = os.open("/dev/i2c-3", os.O_RDWR)
        self.addr = addr
        fcntl.ioctl(self.fd, I2C_SLAVE_FORCE, addr)

    def xfer(self, msgs):
        arr = (i2c_msg * len(msgs))(*msgs)
        fcntl.ioctl(self.fd, I2C_RDWR, i2c_rdwr_ioctl_data(arr, len(msgs)))

    def rd(self, reg):
        wb = ctypes.create_string_buffer(struct.pack(">I", reg), 4)
        rb = ctypes.create_string_buffer(4)
        self.xfer([i2c_msg(self.addr, 0, 4, ctypes.addressof(wb)),
                   i2c_msg(self.addr, I2C_M_RD, 4, ctypes.addressof(rb))])
        return struct.unpack(">I", rb.raw)[0]

    def wr(self, reg, val):
        wb = ctypes.create_string_buffer(struct.pack(">II", reg, val), 8)
        self.xfer([i2c_msg(self.addr, 0, 8, ctypes.addressof(wb))])

    def rmw(self, reg, mask, val):
        self.wr(reg, (self.rd(reg) & ~mask) | val)

mode = sys.argv[1] if len(sys.argv) > 1 else "on"
for name, addr in [("RCV", 0x40), ("LCV", 0x41)]:
    a = Amp(addr)
    if mode == "on":
        a.rmw(0x2024, 0x10, 0x10)          # analog mute while powering
        a.wr(0x6000, 0x1FFC)               # digital mute (att=1023<<3), ramp 4ms
        a.wr(0x4C00, 0x32)                 # DAC from protection DSP
        a.rmw(0x6C04, 0x3E0, 18 << 5)      # amp gain
        a.rmw(0x201C, 0x100010, 0x100010)  # PWR_CTRL3
        a.wr(0x10010, 0xFFFFFFFF)          # clear sticky
        a.wr(0x40, 0x55); a.wr(0x40, 0xAA) # pup patch
        a.wr(0x2084, 0x002F1AA0)
        a.wr(0x40, 0xCC); a.wr(0x40, 0x33)
        a.rmw(0x2014, 1, 1)                # GLOBAL_EN=1
        time.sleep(0.002)
        st1 = a.rd(0x10010)
        # mailbox SPK_OUT_ENABLE (cmd 2) - firmware should raise AMP_EN
        a.wr(0x10814, 1 << 20)
        a.wr(0x10014, 1 << 21)
        a.rmw(0x10914, 1 << 20, 0)
        a.wr(0x13020, 2)
        ack = False
        for _ in range(50):
            time.sleep(0.001)
            if a.rd(0x10014) & (1 << 21):
                ack = True
                break
        mstate = a.rd(0x13004)
        a.wr(0x10014, 1 << 21)
        a.rmw(0x10914, 1 << 20, 1 << 20)
        a.wr(0x6000, 0x0004)               # digital 0dB (att=0), ramp 4ms
        a.rmw(0x2024, 0x10, 0)             # unmute
        print(f"{name}: ST1={st1:#x} mbox ack={ack} state={mstate:#x} "
              f"PWR1={a.rd(0x2014):#x} PWR2={a.rd(0x2018):#x} PWR3={a.rd(0x201C):#x} "
              f"0x2024={a.rd(0x2024):#x} 0x6000={a.rd(0x6000):#x}")
    else:
        a.wr(0x6000, 0x1FFC)
        a.rmw(0x2024, 0x10, 0x10)
        time.sleep(0.005)
        a.rmw(0x2014, 1, 0)
        print(f"{name}: powered down PWR1={a.rd(0x2014):#x}")
    os.close(a.fd)
print(f"AMP_{mode.upper()}_DONE")
